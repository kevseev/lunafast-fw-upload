#!/usr/bin/env python3
"""
Консольный менеджер: подключение к планшетам по сети ADB, просмотр моделей, установка APK.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from rich import box
from rich.align import Align
from rich.console import Console
from rich.layout import Layout
from rich.panel import Panel
from rich.table import Table
from rich.text import Text


DEFAULT_ADB_HOSTS: tuple[tuple[str, int], ...] = (
    ("192.168.1.211", 5555),
    ("192.168.1.213", 5555),
)

console = Console()


def run_adb(args: list[str], timeout: float = 120.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["adb", *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def ensure_adb() -> None:
    try:
        r = run_adb(["version"], timeout=5)
    except FileNotFoundError:
        console.print("[red]adb не найден в PATH. Установите Android Platform Tools.[/red]")
        sys.exit(1)
    if r.returncode != 0:
        console.print("[red]adb version завершился с ошибкой.[/red]")
        sys.exit(1)


def adb_connect(host: str, port: int) -> tuple[bool, str]:
    r = run_adb(["connect", f"{host}:{port}"], timeout=30)
    out = (r.stdout or r.stderr or "").strip()
    ok = r.returncode == 0 and ("connected" in out.lower() or "already" in out.lower())
    return ok, out or f"exit {r.returncode}"


def adb_devices() -> list[str]:
    r = run_adb(["devices", "-l"])
    if r.returncode != 0:
        return []
    lines: list[str] = []
    for line in (r.stdout or "").splitlines():
        line = line.strip()
        if not line or line.startswith("List of devices"):
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            lines.append(parts[0])
    return lines


def get_prop(serial: str, name: str) -> str:
    r = run_adb(["-s", serial, "shell", "getprop", name], timeout=15)
    return (r.stdout or "").strip()


@dataclass
class DeviceInfo:
    serial: str
    model: str
    manufacturer: str
    android_version: str

    @property
    def label(self) -> str:
        m = self.model or "(нет модели)"
        man = self.manufacturer or ""
        if man:
            return f"{man} {m}"
        return m


def collect_device_info(serials: Iterable[str]) -> list[DeviceInfo]:
    out: list[DeviceInfo] = []
    for s in serials:
        out.append(
            DeviceInfo(
                serial=s,
                model=get_prop(s, "ro.product.model"),
                manufacturer=get_prop(s, "ro.product.manufacturer"),
                android_version=get_prop(s, "ro.build.version.release"),
            )
        )
    return out


def install_apk(serial: str, apk: Path) -> tuple[bool, str]:
    r = run_adb(["-s", str(serial), "install", "-r", str(apk.resolve())], timeout=300)
    msg = (r.stdout or r.stderr or "").strip() or f"code {r.returncode}"
    ok = r.returncode == 0 and "success" in msg.lower()
    return ok, msg


def model_matches(info: DeviceInfo, pattern: str | None) -> bool:
    if not pattern:
        return True
    p = pattern.lower()
    hay = f"{info.manufacturer} {info.model}".lower()
    return p in hay


def parse_hosts(host_strings: list[str]) -> list[tuple[str, int]]:
    result: list[tuple[str, int]] = []
    for h in host_strings:
        if ":" in h:
            ip, _, port_s = h.rpartition(":")
            result.append((ip, int(port_s)))
        else:
            result.append((h, 5555))
    return result


def build_layout_title() -> Panel:
    t = Text()
    t.append("  Планшеты ADB  ", style="bold white on blue")
    t.append("  сеть · установка APK  ", style="bold cyan")
    return Panel(Align.center(t), box=box.DOUBLE_EDGE, style="blue")


def build_connect_table(
    hosts: list[tuple[str, int]], results: list[tuple[bool, str]]
) -> Table:
    table = Table(box=box.ROUNDED, show_header=True, header_style="bold magenta")
    table.add_column("Хост", style="cyan")
    table.add_column("Статус", style="green")
    table.add_column("Сообщение")
    for (host, port), (ok, msg) in zip(hosts, results):
        st = "[green]OK[/green]" if ok else "[red]ошибка[/red]"
        table.add_row(f"{host}:{port}", st, msg)
    return table


def build_devices_table(devices: list[DeviceInfo]) -> Table:
    table = Table(box=box.HEAVY_EDGE, show_header=True, header_style="bold yellow")
    table.add_column("#", justify="right", style="dim")
    table.add_column("Serial", style="cyan")
    table.add_column("Производитель")
    table.add_column("Модель", style="bold")
    table.add_column("Android")
    for i, d in enumerate(devices, 1):
        table.add_row(
            str(i),
            d.serial,
            d.manufacturer or "—",
            d.model or "—",
            d.android_version or "—",
        )
    return table


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Подключение к планшетам по Wi‑Fi ADB, список моделей, установка APK."
    )
    parser.add_argument(
        "--host",
        action="append",
        dest="hosts",
        metavar="IP:PORT",
        help="Дополнительный хост (по умолчанию 192.168.1.211:5555 и 192.168.1.213:5555). Повторяйте флаг.",
    )
    parser.add_argument(
        "--model",
        action="append",
        dest="models",
        metavar="SUBSTRING",
        help="Установить APK только на устройства, у которых производитель+модель содержат подстроку (без учёта регистра).",
    )
    parser.add_argument(
        "apks",
        nargs="*",
        type=Path,
        help="Путь к APK для установки (после сканирования устройств).",
    )
    parser.add_argument(
        "--no-ui",
        action="store_true",
        help="Только текстовый вывод без полного псевдографического экрана.",
    )
    args = parser.parse_args()

    hosts = parse_hosts(args.hosts) if args.hosts else list(DEFAULT_ADB_HOSTS)
    model_filters = [m for m in (args.models or []) if m]

    ensure_adb()

    results: list[tuple[bool, str]] = []
    for host, port in hosts:
        results.append(adb_connect(host, port))

    serials = adb_devices()
    devices = collect_device_info(serials)

    if model_filters:
        filtered: list[DeviceInfo] = []
        for d in devices:
            if any(model_matches(d, f) for f in model_filters):
                filtered.append(d)
        target_devices = filtered
    else:
        target_devices = devices

    if args.no_ui:
        for (host, port), (ok, msg) in zip(hosts, results):
            console.print(f"{host}:{port} -> {'OK' if ok else 'FAIL'}: {msg}")
        for d in devices:
            console.print(
                f"{d.serial}\t{d.manufacturer}\t{d.model}\t{d.android_version}"
            )
        if args.apks:
            for apk in args.apks:
                if not apk.is_file():
                    console.print(f"[red]Нет файла: {apk}[/red]")
                    continue
                for d in target_devices:
                    ok, msg = install_apk(d.serial, apk)
                    tag = "OK" if ok else "FAIL"
                    console.print(f"{tag}\t{d.serial}\t{apk.name}\t{msg}")
        return

    layout = Layout()
    layout.split_column(
        Layout(build_layout_title(), name="header", size=5),
        Layout(name="body"),
    )
    layout["body"].split_row(
        Layout(name="left", ratio=1),
        Layout(name="right", ratio=1),
    )
    layout["left"].update(
        Panel(
            build_connect_table(hosts, results),
            title="[bold]Подключение[/bold]",
            border_style="blue",
            box=box.SQUARE,
        )
    )
    layout["right"].update(
        Panel(
            build_devices_table(devices),
            title="[bold]Обнаруженные устройства[/bold]",
            border_style="green",
            box=box.SQUARE,
        )
    )

    console.print(layout)

    if model_filters:
        console.print(
            f"[yellow]Фильтр моделей:[/yellow] {', '.join(model_filters)} "
            f"→ [bold]{len(target_devices)}[/bold] из {len(devices)}"
        )

    if not args.apks:
        console.print(
            "\n[dim]Укажите APK в конце команды для установки, например:[/dim]\n"
            "  [cyan]python tablet_deploy.py /path/app.apk[/cyan]\n"
            "  [cyan]python tablet_deploy.py --model SM-T860 one.apk two.apk[/cyan]"
        )
        return

    apk_paths = [p for p in args.apks if p.is_file()]
    missing = [p for p in args.apks if not p.is_file()]
    for p in missing:
        console.print(f"[red]Пропуск (нет файла): {p}[/red]")

    if not target_devices:
        console.print("[red]Нет целевых устройств для установки.[/red]")
        sys.exit(2)

    if not apk_paths:
        console.print("[red]Нет валидных APK.[/red]")
        sys.exit(2)

    results_table = Table(box=box.DOUBLE, title="Установка APK")
    results_table.add_column("Устройство", style="cyan")
    results_table.add_column("APK")
    results_table.add_column("Результат")

    for apk in apk_paths:
        for d in target_devices:
            ok, msg = install_apk(d.serial, apk)
            if ok:
                results_table.add_row(
                    d.label[:40],
                    apk.name,
                    Text("Success", style="green"),
                )
            else:
                short = msg[:120] + ("…" if len(msg) > 120 else "")
                results_table.add_row(
                    d.label[:40],
                    apk.name,
                    Text(short, style="red"),
                )

    console.print()
    console.print(Panel(results_table, border_style="magenta", box=box.HEAVY))


if __name__ == "__main__":
    main()
