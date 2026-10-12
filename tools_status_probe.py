"""Проверка допущения: правда ли предметы с NON_DROP и PERSONAL_* не продаются на аукционе."""
import asyncio
import sqlite3

from szcore.api import StalZoneAPI
from szcore.config import load_config


async def main() -> None:
    cfg = load_config()
    db = sqlite3.connect(cfg.db_path)
    db.row_factory = sqlite3.Row

    async with StalZoneAPI(cfg.client_id, cfg.client_secret, base_url=cfg.base_url, max_rps=cfg.max_rps) as api:
        for status in ("NON_DROP", "PERSONAL_ON_GET", "PERSONAL_DROP_ON_GET", "PERSONAL_ON_USE"):
            rows = db.execute(
                "SELECT id, name FROM items WHERE status = ? LIMIT 4", (status,)
            ).fetchall()
            print(f"\n=== {status} ===")
            for row in rows:
                try:
                    history = await api.history(cfg.region, row["id"], limit=5)
                    lots = await api.lots(cfg.region, row["id"], limit=5)
                except Exception as exc:
                    print(f"  {row['name'][:30]:30} ошибка: {exc}")
                    continue
                print(
                    f"  {row['name'][:30]:30} продаж: {history.get('total', 0):>6} "
                    f"лотов сейчас: {lots.get('total', 0)}"
                )
    db.close()


asyncio.run(main())
