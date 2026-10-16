"""두 브라우저로 qauser1/qauser2 로그인 -> 로비 나란히 캡처 -> 로그아웃.
사용: <venv>/bin/python example_two_players.py <출력 디렉터리>"""
import asyncio, os, sys
from playwright.async_api import async_playwright
from qa import *


async def main(out):
    os.makedirs(out, exist_ok=True)
    users = ["qauser1", "qauser2"]
    check_accounts(users)
    async with async_playwright() as p:
        bs = [await launch(p) for _ in users]  # 별도 프로세스 = 쿠키 분리
        pgs = [await new_page(b) for b in bs]
        await asyncio.gather(*(login(pg, u) for pg, u in zip(pgs, users)))
        paths = [f"{out}/{u}.png" for u in users]
        for pg, path in zip(pgs, paths):
            await stable(pg, path)
        await side_by_side(bs[0], paths, f"{out}/lobbies.png")
        for b in bs:
            await b.close()
    for u in users:  # 브라우저를 닫은 뒤 REST 로 세션 종료
        t, ck = rest_login(u)
        print(u, rest_get(t, "/api/wallet"))
        rest_logout(t, ck)
    print("saved", f"{out}/lobbies.png")


asyncio.run(main(sys.argv[1]))
