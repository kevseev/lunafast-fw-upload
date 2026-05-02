#!/usr/bin/env python3
"""
Консольный менеджер: подключение к планшетам по сети ADB, просмотр моделей, установка APK.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from rich import box
from rich.align import Align
from rich.console import Console
from rich.layout import Layout
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

try:
    from rich.prompt import Confirm, IntPrompt, Prompt
except ImportError:  # pragma: no cover
    Confirm = IntPrompt = Prompt = None  # type: ignore[misc, assignment]

DEFAULT_SETTINGS: dict[str, Any] = {
    "adb_port": 5555,
    "scan_subnet": "192.168.1",
}

DEFAULT_ADB_HOSTS: tuple[tuple[str, int], ...] = (
    ("192.168.1.211", 5555),
    ("192.168.1.213", 5555),
)

console = Console()


def settings_path() -> Path:
    env = os.environ.get("LUNAFAST_CONFIG")
    if env:
        return Path(env).expanduser()
    return Path.home() / ".lunafast_fw_upload" / "settings.json"


def load_settings() -> dict[str, Any]:
    path = settings_path()
    if not path.is_file():
        return dict(DEFAULT_SETTINGS)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        out = dict(DEFAULT_SETTINGS)
        if isinstance(data.get("adb_port"), int) and 1 <= data["adb_port"] <= 65535:
            out["adb_port"] = data["adb_port"]
        ss = data.get("scan_subnet")
        if isinstance(ss, str) and _valid_subnet_prefix(ss):
            out["scan_subnet"] = ss.strip()
        return out
    except (OSError, json.JSONDecodeError, TypeError):
        return dict(DEFAULT_SETTINGS)


def _valid_subnet_prefix(s: str) -> bool:
    parts = s.strip().rstrip(".").split(".")
    if len(parts) != 3:
        return False
    try:
        return all(0 <= int(p) <= 255 for p in parts)
    except ValueError:
        return False


def save_settings(data: dict[str, Any]) -> None:
    path = settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    to_save = {
        "adb_port": int(data["adb_port"]),
        "scan_subnet": str(data["scan_subnet"]).strip(),
    }
    path.write_text(json.dumps(to_save, ensure_ascii=False, indent=2), encoding="utf-8")


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


def adb_connect(host: str, port: int, *, timeout: float = 30.0) -> tuple[bool, str]:
    r = run_adb(["connect", f"{host}:{port}"], timeout=timeout)
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


def probe_tcp(host: str, port: int, *, timeout: float = 0.35) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def scan_subnet_for_adb(subnet_prefix: str, port: int, *, workers: int = 64) -> list[str]:
    """IP-адреса в prefix.{1..254}, на которых открыт TCP port."""
    base = subnet_prefix.strip().rstrip(".")
    candidates = [f"{base}.{i}" for i in range(1, 255)]
    open_hosts: list[str] = []

    def check(ip: str) -> tuple[str, bool]:
        return ip, probe_tcp(ip, port)

    with ThreadPoolExecutor(max_workers=workers) as ex:
        futures = {ex.submit(check, ip): ip for ip in candidates}
        for fut in as_completed(futures):
            ip, ok = fut.result()
            if ok:
                open_hosts.append(ip)
    open_hosts.sort(key=lambda s: [int(x) for x in s.split(".")])
    return open_hosts


def try_adb_connect_hosts(hosts: list[str], port: int) -> list[tuple[str, bool, str]]:
    results: list[tuple[str, bool, str]] = []
    for h in hosts:
        ok, msg = adb_connect(h, port, timeout=12.0)
        results.append((h, ok, msg))
    return results


def parse_hosts(host_strings: list[str]) -> list[tuple[str, int]]:
    result: list[tuple[str, int]] = []
    for h in host_strings:
        if ":" in h:
            ip, _, port_s = h.rpartition(":")
            result.append((ip, int(port_s)))
        else:
            result.append((h, 5555))
    return result


def build_layout_title(*, subtitle: str | None = None) -> Panel:
    t = Text()
    t.append("  Планшеты ADB  ", style="bold white on blue")
    t.append("  сеть · установка APK  ", style="bold cyan")
    if subtitle:
        t.append("\n")
        t.append(f"  {subtitle}  ", style="dim")
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


def wait_enter() -> None:
    if Prompt is None:
        input("\nНажмите Enter…")
        return
    try:
        Prompt.ask("\n[dim]Enter — в меню[/dim]", default="")
    except EOFError:
        pass


def show_main_menu(settings: dict[str, Any]) -> None:
    port = settings["adb_port"]
    sub = settings["scan_subnet"]
    body = (
        f"[bold white]1[/bold white]. Поиск доступных устройств в сети  "
        f"[dim]({sub}.1–254, TCP {port})[/dim]\n"
        f"[bold white]2[/bold white]. Прошивка / загрузка APK\n"
        f"[bold white]3[/bold white]. Настройки  [dim](порт ADB, подсеть поиска)[/dim]\n"
        f"[bold white]0[/bold white]. Выход"
    )
    console.print(
        Panel(
            body,
            title="[bold cyan]lunafast-fw-upload[/bold cyan]",
            subtitle=f"порт ADB [yellow]{port}[/yellow] · подсеть [yellow]{sub}.x[/yellow]",
            border_style="cyan",
            box=box.ROUNDED,
            padding=(1, 2),
        )
    )


def menu_search_network(settings: dict[str, Any]) -> None:
    port = int(settings["adb_port"])
    subnet = str(settings["scan_subnet"]).strip().rstrip(".")
    console.print(
        Panel(
            f"[bold]Поиск[/bold]: хосты {subnet}.1—254, открытый TCP [bold]{port}[/bold], затем [bold]adb connect[/bold].",
            border_style="blue",
            box=box.SQUARE,
        )
    )
    with console.status("[bold green]Сканирование TCP…"):
        candidates = scan_subnet_for_adb(subnet, port)
    if not candidates:
        console.print("[yellow]Устройств с открытым портом ADB не найдено.[/yellow]")
        wait_enter()
        return
    console.print(f"[green]Открыт порт на {len(candidates)} хостах.[/green] [dim]Подключение adb…[/dim]")
    connect_rows: list[tuple[str, int]] = []
    connect_results: list[tuple[bool, str]] = []
    with console.status("[bold green]adb connect…"):
        for host, ok, msg in try_adb_connect_hosts(candidates, port):
            connect_rows.append((host, port))
            connect_results.append((ok, msg))
    serials = adb_devices()
    devices = collect_device_info(serials)
    layout = Layout()
    layout.split_column(
        Layout(build_layout_title(subtitle="результат поиска"), name="header", size=6),
        Layout(name="body"),
    )
    layout["body"].split_row(Layout(name="left", ratio=1), Layout(name="right", ratio=1))
    layout["left"].update(
        Panel(
            build_connect_table(connect_rows, connect_results),
            title="[bold]Подключение adb[/bold]",
            border_style="blue",
            box=box.SQUARE,
        )
    )
    layout["right"].update(
        Panel(
            build_devices_table(devices),
            title="[bold]Устройства сейчас[/bold]",
            border_style="green",
            box=box.SQUARE,
        )
    )
    console.print(layout)
    wait_enter()


def menu_install_apk() -> None:
    serials = adb_devices()
    devices = collect_device_info(serials)
    if not devices:
        console.print(
            Panel(
                "[red]Нет устройств в состоянии «device».[/red]\n"
                "Сначала выполните п.1 «Поиск» или подключите ADB вручную.",
                border_style="red",
                box=box.ROUNDED,
            )
        )
        wait_enter()
        return
    console.print(
        Panel(
            build_devices_table(devices),
            title="[bold]Цели установки[/bold]",
            border_style="green",
            box=box.HEAVY,
        )
    )
    if Prompt is None:
        path_s = input("Путь к APK: ").strip()
    else:
        path_s = Prompt.ask(
            "Путь к APK [dim](или имя файла из ./apks)[/dim]",
            default="",
        ).strip()
    if not path_s:
        console.print("[yellow]Отмена: пустой путь.[/yellow]")
        wait_enter()
        return
    apk_path = Path(path_s).expanduser()
    if not apk_path.is_file():
        cand = Path("apks") / path_s
        if cand.is_file():
            apk_path = cand
    if not apk_path.is_file():
        console.print(f"[red]Файл не найден: {path_s}[/red]")
        wait_enter()
        return
    if Confirm is None:
        ok_install = input(f"Установить {apk_path.name} на {len(devices)} устройств(а)? y/N: ").lower() in (
            "y",
            "yes",
            "д",
            "да",
        )
    else:
        ok_install = Confirm.ask(
            f"Установить [cyan]{apk_path.name}[/cyan] на [bold]{len(devices)}[/bold] устройств(а)?",
            default=True,
        )
    if not ok_install:
        wait_enter()
        return
    results_table = Table(box=box.DOUBLE, title="Установка APK")
    results_table.add_column("Устройство", style="cyan")
    results_table.add_column("Результат")
    for d in devices:
        ok, msg = install_apk(d.serial, apk_path)
        if ok:
            results_table.add_row(d.label[:48], Text("Success", style="green"))
        else:
            short = (msg or "")[:100] + ("…" if len(msg or "") > 100 else "")
            results_table.add_row(d.label[:48], Text(short, style="red"))
    console.print(Panel(results_table, border_style="magenta", box=box.HEAVY))
    wait_enter()


def menu_settings() -> None:
    s = load_settings()
    console.print(
        Panel(
            f"Порт ADB: [bold]{s['adb_port']}[/bold]\n"
            f"Подсеть поиска: [bold]{s['scan_subnet']}[/bold].x  (сканируются адреса .1–.254)",
            title="[bold]Текущие настройки[/bold]",
            border_style="yellow",
            box=box.ROUNDED,
        )
    )
    if IntPrompt is None or Prompt is None:
        try:
            s["adb_port"] = int(input(f"Порт ADB [{s['adb_port']}]: ").strip() or s["adb_port"])
        except ValueError:
            console.print("[red]Некорректный порт.[/red]")
            wait_enter()
            return
        sub_in = input(f"Подсеть, три октета [{s['scan_subnet']}]: ").strip()
        if sub_in:
            s["scan_subnet"] = sub_in
    else:
        new_port = IntPrompt.ask("Порт ADB", default=int(s["adb_port"]))
        if not (1 <= new_port <= 65535):
            console.print("[red]Порт должен быть 1…65535.[/red]")
            wait_enter()
            return
        s["adb_port"] = new_port
        sub_in = Prompt.ask(
            "Подсеть (три октета, например 192.168.1)",
            default=s["scan_subnet"],
        ).strip()
        s["scan_subnet"] = sub_in
    if not _valid_subnet_prefix(str(s["scan_subnet"])):
        console.print("[red]Некорректная подсеть. Ожидается формат вида 192.168.1[/red]")
        wait_enter()
        return
    save_settings(s)
    console.print("[green]Настройки сохранены:[/green]", settings_path())
    wait_enter()


def run_interactive_menu() -> None:
    ensure_adb()
    if Prompt is None:
        console.print("[red]Нужен rich.prompt (установите rich).[/red]")
        sys.exit(1)
    while True:
        settings = load_settings()
        console.print()
        show_main_menu(settings)
        choice = Prompt.ask(
            "Выберите пункт",
            choices=["0", "1", "2", "3"],
            default="1",
        ).strip()
        if choice == "0":
            console.print("[dim]Выход.[/dim]")
            return
        if choice == "1":
            menu_search_network(settings)
        elif choice == "2":
            menu_install_apk()
        elif choice == "3":
            menu_settings()


def use_interactive_menu(args: argparse.Namespace) -> bool:
    if args.no_ui:
        return False
    if args.apks or args.hosts or args.models:
        return False
    return sys.stdin.isatty()


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
    parser.add_argument(
        "--menu",
        "-m",
        action="store_true",
        help="Интерактивное меню в консоли (поиск, APK, настройки); нужен интерактивный терминал (TTY).",
    )
    args = parser.parse_args()

    if args.menu and args.no_ui:
        parser.error("Нельзя использовать --menu вместе с --no-ui.")
    if args.menu and (args.apks or args.hosts or args.models):
        parser.error("С --menu не указывайте APK, --host и --model — используйте пункты меню.")

    if args.menu:
        if not sys.stdin.isatty():
            console.print(
                "[red]Интерактивное меню нужно запускать в обычном терминале с TTY.[/red]\n"
                "Запустите скрипт локально в консоли (не через пайп без псевдо-TTY)."
            )
            sys.exit(1)
        run_interactive_menu()
        return

    if use_interactive_menu(args):
        run_interactive_menu()
        return

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
        Layout(build_layout_title(), name="header", size=6),
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
