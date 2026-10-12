r"""Утилиты подключения к Greenplum через штатный клиент psql.

Осознанно не используются Python-драйверы (psycopg и т.п.): на машине Python 3.14,
под который колёса драйверов могут отсутствовать. psql есть в любой поставке
Greenplum/PostgreSQL, возвращает текстовый результат и позволяет выполнять
клиентский \copy — этого достаточно и для загрузки, и для автотестов.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys

# Корень репозитория: src/lib/gp.py -> src/lib -> src -> <root>
ROOT = pathlib.Path(__file__).resolve().parents[2]
ENV_FILE = ROOT / ".env"


def load_env(path: pathlib.Path | str = ENV_FILE) -> dict[str, str]:
    """Читает простой KEY=VALUE .env. Пустые строки и # комментарии игнорируются."""
    values: dict[str, str] = {}
    p = pathlib.Path(path)
    if not p.exists():
        return values
    for line in p.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


class Greenplum:
    """Тонкая обёртка: собирает параметры libpq из .env и запускает psql."""

    def __init__(self, env: dict[str, str] | None = None, database: str | None = None):
        env = env or load_env()
        self.settings = env
        self.env = dict(os.environ)
        self.env.update(
            {
                "PGHOST": env.get("GP_HOST", "localhost"),
                "PGPORT": env.get("GP_PORT", "5432"),
                "PGUSER": env.get("GP_USER", "gpadmin"),
                "PGPASSWORD": env.get("GP_PASSWORD", ""),
                "PGSSLMODE": env.get("GP_SSLMODE", "prefer"),
                "PGCLIENTENCODING": "UTF8",
            }
        )
        self.database = database or env.get("GP_DATABASE", "vault_dv")
        self.maintenance_db = env.get("GP_MAINT_DB", "postgres")

    # ------------------------------------------------------------------ utils
    def dsn(self) -> str:
        return (
            f"host={self.env['PGHOST']} port={self.env['PGPORT']} "
            f"user={self.env['PGUSER']} dbname={self.database}"
        )

    def psql(
        self,
        *,
        sql: str | None = None,
        file: str | pathlib.Path | None = None,
        variables: dict[str, str] | None = None,
        db: str | None = None,
        tuples_only: bool = True,
        on_error_stop: bool = True,
        echo: bool = False,
        check: bool = True,
        quiet: bool = True,
    ) -> subprocess.CompletedProcess:
        """Запускает psql. По умолчанию — машинный формат (A|t|F, ON_ERROR_STOP)."""
        cmd = ["psql", "-X"]
        if quiet:
            cmd.append("-q")
        cmd += ["-d", db or self.database]
        if on_error_stop:
            cmd.append("-v")
            cmd.append("ON_ERROR_STOP=1")
        if tuples_only:
            cmd += ["-A", "-t", "-F", "|"]
        for key, value in (variables or {}).items():
            cmd += ["-v", f"{key}={value}"]
        if file is not None:
            cmd += ["-f", str(file)]
        if sql is not None:
            cmd += ["-c", sql]

        result = subprocess.run(cmd, env=self.env, capture_output=True, text=True, cwd=str(ROOT))
        if echo:
            sys.stdout.write(result.stdout)
        if check and result.returncode != 0:
            sys.stderr.write(result.stdout)
            sys.stderr.write(result.stderr)
            raise RuntimeError(f"psql завершился с кодом {result.returncode}: {' '.join(cmd)}")
        return result

    def scalar(self, sql: str, db: str | None = None) -> str:
        """Возвращает первую ячейку запроса как строку."""
        out = self.psql(sql=sql, db=db).stdout.strip().splitlines()
        return out[0] if out else ""

    def rows(self, sql: str, db: str | None = None) -> list[list[str]]:
        """Возвращает все строки результата, разбивая по '|'."""
        text = self.psql(sql=sql, db=db).stdout.strip()
        return [line.split("|") for line in text.splitlines() if line]

    def copy_in(self, table: str, columns: list[str], file_path: str | pathlib.Path) -> None:
        """Клиентский \\copy: читает файл на клиенте (не требует прав на сервере)."""
        script = (
            f"\\copy {table} ({','.join(columns)}) "
            f"FROM '{pathlib.Path(file_path).as_posix()}' WITH (FORMAT csv, HEADER true)\n"
        )
        result = subprocess.run(
            ["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", self.database],
            env=self.env,
            input=script,
            capture_output=True,
            text=True,
            cwd=str(ROOT),
        )
        if result.returncode != 0:
            sys.stderr.write(result.stdout + result.stderr)
            raise RuntimeError("\\copy не выполнился")

    def server_version(self) -> str:
        return self.scalar("SELECT version()")
