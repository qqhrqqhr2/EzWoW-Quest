#!/usr/bin/env python3
"""Draws the README mock-ups of EzWoW - Quest (docs/images/ui_*.png, settings_*.png).

The quest tracker and the settings window are rebuilt from the sizes, coordinates,
colours and strings in the addon code (UI/QuestTracker.lua, UI/OptionsWindow.lua,
Core/Init.lua DEFAULTS, Core/Locales.lua, Modules/QuestObjectivePins.lua, Modules/QuestLogPins.lua), in game
pixels x scale. The map, minimap and item icon are simplified drawings; quests,
NPCs and character names are made up.

usage: python scripts/make_readme_images.py .
Renders with a local headless Chrome (set CHROME=<path> if it is not found).
"""
import base64
import html
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PAGE_W = 1600
CALL = "#7aa2f7"

# ---------------------------------------------------------------------------
# Values read from the Lua code
# ---------------------------------------------------------------------------


def read(root, rel):
    return (root / rel).read_text(encoding="utf-8")


def parse_style(src):
    block = re.search(r"local STYLE = \{(.*?)\n\}", src, re.S).group(1)
    return {k: [float(v) for v in body.split(",")] for k, body in re.findall(r"(\w+)\s*=\s*\{\s*([\d.,\s]+)\}", block)}


def parse_consts(src):
    return {k: int(v) for k, v in re.findall(r"^local ([A-Z_]+) = (-?\d+)\b(?!\.)", src, re.M)}


def parse_colors(src):
    return {k: [float(v) for v in body.split(",")] for k, body in re.findall(r"^local (COLOR_\w+) = \{\s*([\d.,\s]+)\}", src, re.M)}


def parse_quest_colors(src):
    """QUEST_COLORS: one dot colour per quest, in quest log order."""
    block = re.search(r"^local QUEST_COLORS = \{(.*?)^\}", src, re.S | re.M).group(1)
    return [[float(v) for v in body.split(",")] for body in re.findall(r"\{\s*([\d.,\s]+)\}", block)]


def parse_defaults(src):
    block = re.search(r"ns\.DEFAULTS = \{(.*?)\n\}", src, re.S).group(1)
    out = {}
    for k, v in re.findall(r"^\s*(\w+)\s*=\s*([^,\n]+),", block, re.M):
        v = v.strip()
        out[k] = True if v == "true" else False if v == "false" else v.strip('"')
    return out


def parse_locale(src, var):
    start = src.index(f"local {var} = {{")
    end = src.index("\n}", start)
    return {k: v.replace('\\"', '"').replace("\\n", "\n")
            for k, v in re.findall(r'^\s*(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', src[start:end], re.M)}


def parse_options(src):
    """Section headers, check boxes (x, y, width), their label keys and default checks."""
    sections = {name: int(y) for name, y in re.findall(r"windowFrame\.(\w+) = SettingsDialog\.buildSectionHeader\(windowFrame, (-?\d+)\)", src)}
    checks = {}
    for name, x, y in re.findall(r"windowFrame\.(\w+) = SettingsDialog\.buildFlatCheckbox\(windowFrame, (\d+), (-?\d+)", src):
        checks[name] = {"x": int(x), "y": int(y), "w": 440}
    qw = int(re.search(r"end, (\d+)\)\s*\n\s*end", src).group(1))
    for name, x, y in re.findall(r'windowFrame\.(\w+) = questCheck\((\d+), (-?\d+), "\w+"\)', src):
        checks[name] = {"x": int(x), "y": int(y), "w": qw}
    for name, key in re.findall(r'setFittedLabel\(w\.(\w+), self:L\("(\w+)"\)\)', src):
        if name in checks:
            checks[name]["label"] = key
        else:
            checks.setdefault("_buttons", {})[name] = key
    for name, field, op in re.findall(r"w\.(\w+):SetChecked\(savedDB\.(\w+) (~= false|== true)\)", src):
        checks[name]["field"], checks[name]["op"] = field, op
    size = re.search(r"windowFrame:SetSize\((\d+), (\d+)\)", src)
    return sections, checks, (int(size.group(1)), int(size.group(2)))


def parse_version(src):
    m = re.search(r"^## Version:\s*(\S+)", src, re.M)
    return m.group(1) if m else ""


def css(c, alpha=None, mul=1.0):
    r, g, b = (round(min(1, v * mul) * 255) for v in c[:3])
    a = alpha if alpha is not None else (c[3] if len(c) > 3 else 1)
    return f"rgba({r},{g},{b},{a:.2f})"


def hexc(c):
    return "#%02x%02x%02x" % tuple(round(v * 255) for v in c[:3])


# ---------------------------------------------------------------------------
# Game colour rules used by the tracker
# ---------------------------------------------------------------------------
PLAYER_LEVEL = 11


def difficulty(level):
    """Client quest difficulty colours relative to the player level."""
    d = level - PLAYER_LEVEL
    if d >= 5:
        return "#ff1a1a"
    if d >= 3:
        return "#ff8040"
    if d >= -2:
        return "#ffd100"
    if d >= -8:
        return "#40bf40"
    return "#808080"


def progress(have, need, finished=False):
    """resolveObjectiveProgressHex in UI/QuestTracker.lua."""
    if finished or (need and have >= need):
        return "#40ff59"
    if have <= 0:
        return "#dce6ec"
    pct = max(0.0, min(1.0, have / need))
    if pct < 0.5:
        v = pct * 2
        r, g, b = 1.0, 0.55 + 0.35 * v, 0.38 - 0.08 * v
    else:
        v = (pct - 0.5) * 2
        r, g, b = 1.0 - 0.45 * v, 0.90 + 0.10 * v, 0.30 + 0.05 * v
    return hexc((r, g, b))


# ---------------------------------------------------------------------------
# Texts (quests, NPCs and names are made up; UI strings come from Core/Locales.lua)
# ---------------------------------------------------------------------------
T = {
    "ko": {
        "lead": "퀘스트 추적기, 자동 수락·완료, 파티 진행 알림, 지도와 미니맵의 퀘스트 목표·보고 위치, 받을 수 있는 퀘스트(!) 표시",
        "zones": ["엘윈 숲", "서부 몰락지대"],
        "q": {
            "wolf": "늑대 무리 쫓아내기", "wolfObj": "굶주린 회색 늑대 처치",
            "supply": "흩어진 보급품", "supplyObj": "보급 상자", "supplyObj2": "신호 피리 사용",
            "mine": "광산 정찰",
            "bandit": "들판의 도적단", "banditObj": "도적단 정찰병 처치", "banditObj2": "도적단 명령서",
            "crow": "허수아비 조사", "crowObj": "수상한 허수아비 조사",
            "late": "늦은 배달",
            "necklace": "잃어버린 목걸이", "necklaceObj": "할머니의 목걸이",
            "letter": "집으로 보내는 편지",
        },
        "npc": "경비대장 로웬", "giver": "농부 알드릭",
        "gq": ["방앗간에 보낼 밀", "대장간 연장 배달"],
        "mapTitle": "엘윈 숲",
        "me": "이끼발톱",
        "party": "파티",
        "notes": [
            ("추적기 머리줄", "수행 중인 퀘스트 수/최대 수. 좌클릭: 목록 접기·펼치기, 우클릭: 설정창. 끌어서 이동, Ctrl + 휠로 크기 50~150%. 마우스를 올리면 나오는 자물쇠 버튼으로 위치·크기를 잠급니다(잠기면 배경이 투명해지고 Ctrl + 끌기로만 이동)."),
            ("지역 헤더", "퀘스트를 지역별로 묶습니다. 클릭하면 그 지역을 접습니다."),
            ("퀘스트 아이템 버튼", "사용 아이템이 있는 퀘스트는 왼쪽 버튼을 눌러 바로 씁니다."),
            ("퀘스트 줄", "[레벨]을 난이도 색으로(던전은 [16D], 정예는 [21+]처럼 표시), (완료)·(실패)를 바로 표시. 파티 중에는 줄 끝에 같은 퀘스트를 가진 파티원 수([2/2] 초록 = 모두, [1/2] 보라 = 일부, [0/2] 회색 = 없음)를 보여 주고, 마우스를 올리면 파티원별로 나옵니다. 좌클릭: 퀘스트 로그와 함께 가장 가까운 수행 위치로 길 안내, Ctrl + 좌클릭: 퀘스트 로그만, Shift + 좌클릭: 채팅 링크, Alt + 좌클릭: 파티에 공유, 우클릭: 목표 접기, Alt + 우클릭: 숨기기."),
            ("목표 진행 색", "아직 0이면 흰색, 진행할수록 주황 → 노랑 → 연두, 다 채우면 초록."),
            ("크기 조절", "아래 모서리를 끌어 가로·세로 크기 조절(기본 270×360, 우클릭: 초기화). 목록이 길면 마우스 휠로 스크롤."),
            ("목표 위치 (퀘스트마다 다른 색 점)", "처치할 몬스터와 모으거나 사용할 대상의 자리를 퀘스트마다 다른 색(빨강·파랑·초록·분홍·주황·하늘·보라·흰색 순)으로 표시합니다. 가까운 점은 같은 색 선으로 이어 사냥터 범위를 보여 줍니다. 목표가 분명하지 않은 퀘스트는 찾아볼 곳을 보여 줍니다. 마우스를 올리면 같은 색의 퀘스트 이름과 목표, 클릭하면 웨이포인트."),
            ("퀘스트 지역 (금색 고리)", "목표 위치 점이 없는 퀘스트(몬스터가 떨어뜨리는 아이템 등)는 게임이 알려 주는 퀘스트 지역을 속이 빈 금색 고리로 표시합니다."),
            ("보고 위치 (?)", "목표를 다 채운 퀘스트를 주거나 받는 NPC를 금색 테두리의 작은 어두운 원 안에 노란 ?로 표시합니다. 옵션을 켜면 진행 중인 퀘스트도 회색 ?로 표시합니다."),
            ("미니맵", "가까운 목표 점과 퀘스트 지역을 미니맵에도 표시합니다."),
            ("파티 진행 알림", "파티(인스턴스 그룹)에 수락 · 목표 진행 · 목표 달성 · 완료를 알립니다. 공격대에서는 보내지 않습니다."),
            ("받을 수 있는 퀘스트 (!)", "지금 받을 수 있는 퀘스트가 있는 NPC를 노란 !로 표시합니다. 진영·직업·전문 기술·레벨이 맞고 앞 단계 퀘스트를 마친 퀘스트만 나오고, 명절·이벤트·기부·전장 퀘스트와 너무 낮은 레벨의 퀘스트는 빠집니다. 마우스를 올리면 퀘스트 목록, 클릭하면 웨이포인트. NPC와 미니맵 툴팁에도 받을 퀘스트와 보고할 퀘스트가 나옵니다."),
        ],
        "foot": "애드온 코드의 창 크기·좌표·색상·문구로 재현한 예시 화면입니다. 지도·미니맵·아이콘은 단순화한 그림이고, 퀘스트·NPC·캐릭터 이름은 지어낸 예시입니다. 지도 표시에는 EzWoW - Map Finder가 필요합니다.",
        "sTitle": "설정창",
        "sLead": "/ezq · /퀘스트 · 추적기, 퀘스트 자동화, 지도·미니맵 표시",
        "sNotes": [
            ("언어", "자동 또는 8개 언어 중 선택."),
            ("퀘스트 추적 목록", "EzWoW 추적기 사용(끄면 게임 기본 추적창), 기본 추적창 숨기기, 모든 퀘스트 자동 표시, 지역 헤더·[레벨] 난이도 색, 배경·테두리(끄면 글자만 보이는 투명 모드). 추적기를 끄면 아래 항목은 흐려집니다."),
            ("퀘스트 자동화", "자동 수락(Shift를 누르고 대화하면 건너뜀)·자동 완료는 처음에 꺼져 있습니다. 반복·회색 퀘스트 제외, 아이템을 내는 퀘스트 제외, 판매가가 가장 높은 보상 표시, 파티 진행 알림, 수락한 퀘스트를 파티에 공유(처음에는 꺼짐), 추적기에 파티원의 퀘스트 보유 표시."),
            ("지도·미니맵 표시", "완료한 퀘스트의 보고 위치(노란 ?), 진행 중인 퀘스트 위치(회색 ?, 처음에는 꺼짐), 목표 위치 점, 받을 수 있는 퀘스트를 주는 NPC(노란 !). EzWoW - Map Finder가 없으면 이 항목은 흐려지고 빨간 안내 문구가 나옵니다."),
            ("하단", "설정 기본값 복원(언어와 모아 둔 퀘스트 정보는 유지), 추적기 위치·크기 초기화."),
        ],
        "sFoot": "애드온 코드의 창 크기·좌표·색상·문구로 재현한 예시 화면입니다. 체크 상태는 기본값입니다(EzWoW - Map Finder가 함께 켜져 있을 때).",
    },
    "en": {
        "lead": "Quest tracker, auto accept & turn-in, party progress messages, and objective, turn-in and quest giver (!) spots on the map and minimap",
        "zones": ["Elwynn Forest", "Westfall"],
        "q": {
            "wolf": "Driving Off the Wolf Pack", "wolfObj": "Hungry Grey Wolf slain",
            "supply": "Scattered Supplies", "supplyObj": "Supply Crate", "supplyObj2": "Signal Whistle used",
            "mine": "Scouting the Mine",
            "bandit": "Bandits in the Fields", "banditObj": "Bandit Scout slain", "banditObj2": "Bandit Orders",
            "crow": "The Scarecrow Survey", "crowObj": "Suspicious Scarecrow inspected",
            "late": "A Late Delivery",
            "necklace": "The Lost Necklace", "necklaceObj": "Grandmother's Necklace",
            "letter": "A Letter Home",
        },
        "npc": "Guard Captain Rowen", "giver": "Farmer Aldric",
        "gq": ["Wheat for the Mill", "Tools for the Smithy"],
        "mapTitle": "Elwynn Forest",
        "me": "Mossclaw",
        "party": "Party",
        "notes": [
            ("Tracker header", "Active quests / maximum. Left-click: collapse or expand, right-click: settings. Drag to move, Ctrl + wheel scales it 50–150%. The lock button that appears on hover locks position and size (locked: see-through background, moves only with Ctrl + drag)."),
            ("Zone header", "Quests are grouped by zone. Click a zone to collapse it."),
            ("Quest item button", "Quests with a usable item get a button on the left; click it to use the item."),
            ("Quest line", "[Lv] in difficulty colour (dungeons read [16D], elite quests [21+]), (Complete) and (Failed) at once. In a party the line ends with how many members also have the quest ([2/2] green = all, [1/2] violet = some, [0/2] grey = none); hover to see each member. Left-click: quest log plus a guide to the nearest place to go, Ctrl + left-click: quest log only, Shift + left-click: chat link, Alt + left-click: share with party, right-click: fold objectives, Alt + right-click: hide."),
            ("Objective colours", "White at 0, then orange → yellow → light green as you progress, green when done."),
            ("Resize", "Drag the bottom corner to resize (default 270×360, right-click: reset). Long lists scroll with the mouse wheel."),
            ("Objective dots (one colour per quest)", "Where the creatures to kill and the things to collect or use are, in one colour per quest (red, blue, green, pink, orange, cyan, violet, white in turn). Nearby dots are joined by thin lines of the same colour so a hunting ground reads as one area. Quests with unclear objectives show places to search. Hover for the quest name in that colour and its objectives, click for a waypoint."),
            ("Quest area (gold ring)", "Quests without objective dots (such as items dropped by creatures) get a hollow gold ring at the game's own quest area."),
            ("Turn-in spots (?)", "The quest giver or turn-in NPC of quests whose objectives are done: a yellow ? in a small dark badge with a gold rim. An option also shows quests in progress with a grey ?."),
            ("Minimap", "Nearby objective dots and quest areas show on the minimap too."),
            ("Party progress messages", "Tells your party (or instance group) when you accept a quest, make progress, finish the objectives and turn it in. Never sent in a raid."),
            ("Quests you can take (!)", "NPCs with a quest you can take now get a yellow !. Only quests that match your side, class, profession and level, with earlier quests in the chain done; holiday, event, donation, battleground and low-level quests are left out. Hover for the quests, click for a waypoint. NPC and minimap tooltips also list quests to take and to hand in."),
        ],
        "foot": "Mock-up rebuilt from the window sizes, coordinates, colours and strings in the addon code. The map, minimap and icons are simplified drawings; quests, NPCs and character names are made up. Map marks need EzWoW - Map Finder.",
        "sTitle": "Settings",
        "sLead": "/ezq · tracker, quest automation, map & minimap marks",
        "sNotes": [
            ("Language", "Auto or one of 8 languages."),
            ("Quest tracker", "Use the EzWoW tracker (off = game default tracker), hide the default tracker, show all active quests, zone headers and difficulty-coloured [Lv], background and frame (off = see-through, text only). The options below dim while the tracker is off."),
            ("Quest automation", "Auto accept (hold Shift while talking to skip) and auto turn-in start off. Skip repeatable and grey quests, skip quests that take items, mark the reward that sells for most, party progress messages, share accepted quests with the party (off by default), party members' quests in the tracker."),
            ("Map & minimap marks", "Turn-in spots of finished quests (yellow ?), spots of quests in progress (grey ?, off by default), objective dots, NPCs with quests you can take (yellow !). Without EzWoW - Map Finder these options dim and a red note appears."),
            ("Bottom", "Restore defaults (keeps the language and the learned quest data), reset the tracker position and size."),
        ],
        "sFoot": "Mock-up rebuilt from the window size, coordinates, colours and strings in the addon code. Check boxes show the defaults (with EzWoW - Map Finder enabled).",
    },
}

# quests in the tracker: zone index, key, level (with the short tag suffix), state (0 / 1 complete / -1 failed), objectives, item, focus
# objective = (text key, have, need)
QUESTS = [
    (0, "wolf", 8, 0, [("wolfObj", 5, 8)], False, False),
    (0, "supply", 9, 0, [("supplyObj", 1, 4), ("supplyObj2", 0, 1)], True, False),
    (0, "mine", 7, 1, [], False, False),
    (0, "necklace", 10, 0, [("necklaceObj", 0, 1)], False, False),
    (1, "bandit", "14+", 0, [("banditObj", 0, 10), ("banditObj2", 0, 1)], False, True),
    (1, "crow", 12, 0, [("crowObj", 3, 4)], False, False),
    (1, "late", 11, -1, [], False, False),
]

# party members that also have each quest (have, party members) -> "[have/known]" at the line end
PARTY = {"wolf": (2, 2), "supply": (1, 2), "mine": (2, 2), "necklace": (0, 2), "bandit": (1, 2), "crow": (2, 2), "late": (0, 2)}


def parse_party_hex(src):
    """PARTY_HEX_ALL / _SOME / _NONE in UI/QuestTracker.lua."""
    return {k.lower(): "#" + v for k, v in re.findall(r'^local PARTY_HEX_(\w+) = "\|cff([0-9a-fA-F]{6})"', src, re.M)}


# ---------------------------------------------------------------------------
# Page parts
# ---------------------------------------------------------------------------
S = 1.6  # game px -> page px (set per page)


def px(v):
    return f"{v * S:.2f}px"


def esc(s):
    return html.escape(s, quote=False)


SHADOW = "text-shadow:1px 1px 0 #000,0 0 2px rgba(0,0,0,.8);"
OUTLINE = "text-shadow:-1px 0 #000,1px 0 #000,0 -1px #000,0 1px #000,0 0 3px #000;"

CSS = f"""
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
body {{ width: {PAGE_W}px; overflow: hidden; background: radial-gradient(ellipse at 30% 0%, #1f2a3d 0%, #121922 55%, #0b1014 100%);
  font-family: 'Noto Sans KR', 'Malgun Gothic', sans-serif; color: #edf4f7; }}
.page {{ position: relative; padding: 34px 50px 40px; }}
h1 {{ color: {CALL}; font-size: 40px; font-weight: 700; letter-spacing: .3px; display: flex; align-items: center; gap: 14px; }}
h1 .badge {{ font-size: 15px; background: {CALL}; color: #0b1430; padding: 2px 9px; border-radius: 5px; }}
.lead {{ color: #d5dde2; font-size: 19px; margin-top: 6px; }}
.abs {{ position: absolute; }}
.t {{ position: absolute; white-space: nowrap; line-height: 1; }}
.call {{ position: absolute; width: 30px; height: 30px; border-radius: 50%; background: {CALL}; color: #0b1430; font-weight: 700;
  font-size: 16px; display: flex; align-items: center; justify-content: center; border: 2px solid #0b1430; box-shadow: 0 0 0 2px {CALL}55; z-index: 50; }}
.notes {{ position: absolute; }}
.note {{ display: flex; gap: 12px; margin-bottom: 10px; font-size: 16px; line-height: 1.5; color: #dfe6ea; }}
.note .n {{ flex: none; width: 28px; height: 28px; border-radius: 50%; background: {CALL}; color: #0b1430; font-weight: 700;
  font-size: 15px; display: flex; align-items: center; justify-content: center; }}
.note b {{ color: #fff; }}
.foot {{ color: #7d8d98; font-size: 13.5px; line-height: 1.5; }}
.fit {{ display: inline-block; }}
.tip {{ position: absolute; background: rgba(6,10,16,.94); border: 2px solid #5d6d7a; border-radius: 4px; padding: 7px 11px;
  font-size: 14px; line-height: 1.5; white-space: nowrap; z-index: 20; }}
.tl {{ font-size: {10.5 * 1.6:.1f}px; line-height: {13 * 1.6:.1f}px; white-space: normal; {SHADOW} }}
"""

FIT_JS = """
<script>
document.querySelectorAll('[data-fit]').forEach(function (e) {
  var max = parseFloat(e.dataset.fit), min = parseFloat(e.dataset.min || 8);
  var fs = parseFloat(getComputedStyle(e).fontSize);
  while (e.scrollWidth > max && fs > min) { fs -= 0.25; e.style.fontSize = fs + 'px'; }
});
</script>
"""


def box(x, y, w, h, style="", inner=""):
    return f'<div class="abs" style="left:{px(x)};top:{px(y)};width:{px(w)};height:{px(h)};{style}">{inner}</div>'


def notes_height(notes, width):
    h = 0
    for a, b in notes:
        chars = len(a) + len(b) + 3
        wide = sum(1 for ch in a + b if ord(ch) > 0x2e80)
        per_line = width / (8.4 + 7.4 * wide / chars)
        h += max(1, math.ceil(chars / per_line)) * 24 + 10
    return h


# ---------------------------------------------------------------------------
# Quest tracker (UI/QuestTracker.lua)
# ---------------------------------------------------------------------------
ITEM_ICON = ('<svg viewBox="0 0 32 32" width="100%" height="100%"><defs><linearGradient id="ig" x1="0" y1="0" x2="1" y2="1">'
             '<stop offset="0" stop-color="#5b4a33"/><stop offset="1" stop-color="#231a10"/></linearGradient></defs>'
             '<rect width="32" height="32" fill="url(#ig)"/>'
             '<path d="M6 21 L20 9 Q24 6 26 9 Q28 12 24 15 L10 25 Z" fill="#c9ccd2" stroke="#2a2d33" stroke-width="1.5"/>'
             '<circle cx="23" cy="11" r="2.4" fill="#2a2d33"/><path d="M6 21 L10 25 L6 27 Z" fill="#e3b448"/></svg>')


def tracker(ctx, lang, ox, oy):
    """Returns (html, anchors) for the tracker placed at page px (ox, oy)."""
    t, L, st, k = T[lang], ctx["L"][lang], ctx["tstyle"], ctx["tconst"]
    W = k["TRACKER_DEFAULT_WIDTH"]
    BH = k["TRACKER_DEFAULT_HEIGHT"]
    HH = k["HEADER_HEIGHT"]
    PAD = k["LINE_PADDING_X"]
    p = []
    a = {}
    # header
    p.append(box(0, 0, W, HH, f"background:{css(st['header'])};border:1px solid {css(st['border'])}"))
    p.append(box(1, HH - 1, W - 2, 1, f"background:{css(st['accent'])}"))
    p.append(f'<img class="abs" src="{ctx["icon"]}" style="left:{px(6)};top:{px((HH - 16) / 2)};width:{px(16)};height:{px(16)}">')
    p.append(f'<div class="t" style="left:{px(28)};top:{px(HH / 2)};transform:translate(0,-50%);font-size:{px(10.5)};color:{css(st["text"])};{SHADOW}">'
             f'{esc(L["TRACKER_HEADER_FORMAT"].replace("%d", "{}").format(len(QUESTS), 20))}</div>')
    p.append(f'<div class="t" style="right:{px(8)};top:{px(HH / 2)};transform:translate(0,-50%);font-size:{px(10.5)};color:{css(st["accent"])};{SHADOW}">[-]</div>')
    # body
    by = HH + 2
    p.append(box(0, by, W, BH, f"background:{css(st['bgMain'])};border:1px solid {css(st['border'])}"))
    # bottom-right resize grip (3 bars, 3/6/9 high)
    for i, h in enumerate((3, 6, 9)):
        x = W - 1 - 2 - (2 - i) * 3 - 2
        p.append(box(x, by + BH - 1 - 2 - h, 2, h, f"background:{css(st['textSub'], .55)}"))
    a["grip"] = (W - 8, by + BH - 8)

    inner = W - 18
    rows = []
    y = -4  # yOffset inside the scroll child
    zone_y = {}
    for zi, zone in enumerate(t["zones"]):
        zone_y[zi] = y
        rows.append(f'<div class="abs tl" style="left:{px(PAD - 2)};top:{px(-y)};width:{px(inner - 10)};font-size:{px(10.5)};color:{css(st["zone"])}">'
                    f'▾ {esc(zone)}</div>')
        y -= 15 + 2
        for (qz, key, lvl, state, objs, item, focus) in QUESTS:
            if qz != zi:
                continue
            indent = 0
            if item:
                rows.append(box(PAD - 2, -y, 20, 20, f"background:{css(st['border'], .95)};padding:{px(1)}",
                                f'<div style="width:100%;height:100%;overflow:hidden">{ITEM_ICON}</div>'))
                a["item"] = (PAD - 2 + 10, -y + 10)
                indent = 23
            a.setdefault("quest_" + key, -y)
            fm = f'<span style="color:#7aa2f7">▸ </span>' if focus else ""
            suffix = ""
            if state == 1:
                suffix = f' <span style="color:#40ff59">{esc(L["TRACKER_COMPLETE_TAG"])}</span>'
            elif state == -1:
                suffix = f' <span style="color:#ff5555">{esc(L["TRACKER_FAILED_TAG"])}</span>'
            if key in PARTY:
                have, known = PARTY[key]
                ph = ctx["phex"]["all" if have >= known else "some" if have > 0 else "none"]
                suffix += f' <span style="color:{ph}">[{have}/{known}]</span>'
            rows.append(f'<div class="abs tl" style="left:{px(PAD - 2 + indent)};top:{px(-y)};width:{px(inner - 8 - indent)}">'
                        f'<span class="abs" style="left:0;top:{px(-1)};width:{px(14)};height:{px(14)};text-align:center;color:{css(st["textSub"])}">-</span>'
                        f'<div style="margin-left:{px(15)};color:{difficulty(int(str(lvl).rstrip("+DRP")))}">{fm}[{lvl}] {esc(t["q"][key])}{suffix}</div></div>')
            y -= 15 + 1
            ow = inner - 26 - indent
            if state == 1 and not objs:
                lines = [(f'• {L["TRACKER_QUEST_COMPLETE"]}', "#40ff59")]
            elif state == -1:
                lines = [(f'• {L["TRACKER_QUEST_FAILED"]}', "#ff5555")]
            else:
                lines = [(f'• {t["q"][ok]}: {have}/{need}', progress(have, need)) for ok, have, need in objs]
            for i, (text, col) in enumerate(lines):
                if key == "wolf" and i == 0:
                    a["obj"] = -y
                rows.append(f'<div class="abs tl" style="left:{px(PAD + 13 + indent)};top:{px(-y)};width:{px(ow)};color:{col}">{esc(text)}</div>')
                y -= 14 + 1
            y -= 3
    a["zone0"] = -zone_y[0]
    a["zone1"] = -zone_y[1]
    # scroll child at (2, -4) inside the body
    p.append(f'<div class="abs" style="left:{px(2)};top:{px(by + 4)};width:{px(inner)};height:{px(BH - 12)};overflow:hidden">{"".join(rows)}</div>')
    for key in list(a):
        if isinstance(a[key], (int, float)):
            a[key] = by + 4 + a[key] + 7
    html_ = f'<div class="abs" style="left:{ox}px;top:{oy}px;width:{px(W)};height:{px(HH + 2 + BH)}">' + "".join(p) + "</div>"
    return html_, a, (W, HH + 2 + BH)


# ---------------------------------------------------------------------------
# World map panel (simplified drawing) with the marks of Modules/QuestObjectivePins.lua
# and Modules/QuestLogPins.lua
# ---------------------------------------------------------------------------
WOLVES_A = [(120, 70), (165, 52), (205, 88), (150, 112), (232, 132), (98, 125), (190, 160), (262, 84), (70, 88)]
WOLVES_B = [(70, 300), (112, 322), (56, 345), (100, 362)]
CRATES = [(318, 286), (366, 272), (412, 302), (384, 346), (334, 350), (431, 362)]
RING = (640, 382)
TURNIN = (800, 196)
GIVERS = [(600, 40), (250, 236)]  # NPCs with a quest to take now; the first one shows its tooltip


def nets(points, radius, neighbours=2):
    """Each point joined to its two nearest neighbours within radius (drawNets)."""
    edges = set()
    for i, (ax, ay) in enumerate(points):
        near = sorted((((ax - bx) ** 2 + (ay - by) ** 2), j) for j, (bx, by) in enumerate(points) if j != i)
        for d, j in [n for n in near if n[0] <= radius * radius][:neighbours]:
            edges.add((min(i, j), max(i, j)))
    return [(points[i], points[j]) for i, j in sorted(edges)]


def disc(x, y, size, color, alpha=1.0):
    return (f'<div class="abs" style="left:{x - size / 2:.2f}px;top:{y - size / 2:.2f}px;width:{size:.2f}px;height:{size:.2f}px;'
            f'border-radius:50%;background:{color};opacity:{alpha}"></div>')


def dot(x, y, size, color, inset=3):
    """Objective dot: black disc with a coloured fill (size - 3; minimap size - 2)."""
    return disc(x, y, size, "#000", .95) + disc(x, y, size - inset * DS, color)


def area(x, y, size, color):
    """Quest area: dark shadow, gold ring (size - 2), dark core (size - 7), pin alpha .85."""
    return ('<div class="abs" style="left:0;top:0;opacity:.85">' + disc(x, y, size, "#000", .7) + disc(x, y, size - 2 * DS, color)
            + disc(x, y, size - 7 * DS, "rgba(13,13,13,.75)") + "</div>")


def turnin_badge(x, y, ready=True):
    """Turn-in mark (QuestLogPins.obtainPin): gold rim 16, dark disc 14, "?" icon 12."""
    q = "#ffd200" if ready else "#b4b4b4"
    return (disc(x, y, 16 * DS, "rgb(242,217,115)", .95) + disc(x, y, 14 * DS, "rgb(20,15,10)", .92)
            + f'<div class="t" style="left:{x}px;top:{y + 0.5 * DS:.2f}px;transform:translate(-50%,-50%);font-size:{14 * DS:.0f}px;font-weight:800;'
              f'color:{q};text-shadow:0 0 2px #000,1px 1px 0 #000">?</div>')


def giver_badge(x, y):
    """Quest giver mark (QuestLogPins.obtainGiverPin, state "now"): gold rim 16, dark disc 14, yellow "!" icon 12."""
    return (disc(x, y, 16 * DS, "rgb(242,217,115)", .95) + disc(x, y, 14 * DS, "rgb(20,15,10)", .92)
            + f'<div class="t" style="left:{x}px;top:{y + 0.5 * DS:.2f}px;transform:translate(-50%,-50%);font-size:{14 * DS:.0f}px;font-weight:800;'
              f'color:#ffd200;text-shadow:0 0 2px #000,1px 1px 0 #000">!</div>')


DS = 1.6  # marks keep their screen size; drawn at the same scale as the tracker


def quest_colors(ctx):
    """Dot colour of each unfinished quest, in quest log order (rebuildQuests)."""
    pal = ctx["qcolors"]
    out, i = {}, 0
    for (_z, key, _lvl, state, _objs, _item, _focus) in QUESTS:
        if state != 1:
            out[key] = hexc(pal[i % len(pal)])
            i += 1
    return out


def map_panel(ctx, lang, x0, y0, w, h):
    t, L, pc = T[lang], ctx["L"][lang], ctx["pins"]
    qc = quest_colors(ctx)
    title = hexc(pc["COLOR_TITLE"])
    q = t["q"]
    dot_size, area_size = ctx["pconst"]["DOT_SIZE"] * DS, ctx["pconst"]["AREA_SIZE"] * DS
    radius = ctx["pconst"]["NET_RADIUS"] * DS
    TB = 30
    ch = h - TB
    terrain = (f'<svg class="abs" style="left:0;top:{TB}px" width="{w}" height="{ch}" viewBox="0 0 {w} {ch}">'
               '<defs><radialGradient id="gr" cx="45%" cy="45%" r="75%"><stop offset="0" stop-color="#6e7f45"/>'
               '<stop offset="1" stop-color="#4c5b31"/></radialGradient></defs>'
               f'<rect width="{w}" height="{ch}" fill="url(#gr)"/>'
               '<path d="M0 0 H330 Q300 60 340 120 Q290 200 200 210 Q90 230 0 200 Z" fill="#41532c" opacity=".75"/>'
               f'<path d="M0 260 Q80 240 160 270 Q210 330 180 {ch} H0 Z" fill="#3e4f2a" opacity=".8"/>'
               f'<path d="M680 {ch} Q690 390 720 340 Q770 290 840 300 Q880 302 910 290 V{ch} Z" fill="#4f7f9a"/>'
               f'<path d="M690 {ch} Q700 395 728 348 Q775 302 842 311 Q882 312 910 302" fill="none" stroke="#c9b98a" stroke-width="4" opacity=".55"/>'
               '<path d="M0 215 Q200 210 360 200 Q560 185 700 140 Q760 120 910 92" fill="none" stroke="#a88f5f" stroke-width="9" stroke-linecap="round"/>'
               f'<path d="M520 186 Q545 300 515 {ch}" fill="none" stroke="#a88f5f" stroke-width="7"/>'
               '<g fill="#8d8478" stroke="#3a352e" stroke-width="2">'
               '<rect x="730" y="84" width="22" height="18"/><rect x="796" y="76" width="26" height="20"/>'
               '<rect x="742" y="142" width="24" height="18"/><rect x="826" y="140" width="20" height="16"/></g>'
               '</svg>')
    p = [terrain]
    # title bar
    p.append(f'<div class="abs" style="left:0;top:0;width:{w}px;height:{TB}px;background:linear-gradient(#26313b,#161d24);border-bottom:2px solid #5d6d7a"></div>')
    p.append(f'<div class="t" style="left:{w / 2}px;top:{TB / 2}px;transform:translate(-50%,-50%);font-size:16px;color:#ffd100;{OUTLINE}">{esc(t["mapTitle"])}</div>')
    groups = ((WOLVES_A, qc["wolf"]), (WOLVES_B, qc["wolf"]), (CRATES, qc["supply"]))
    # nets in the quest colour
    lines = []
    for pts, col in groups:
        for (ax, ay), (bx, by) in nets(pts, radius):
            lines.append(f'<line x1="{ax}" y1="{ay}" x2="{bx}" y2="{by}" stroke="{col}" stroke-opacity=".45" stroke-width="{1.2 * DS:.2f}"/>')
    p.append(f'<svg class="abs" style="left:0;top:{TB}px" width="{w}" height="{ch}">{"".join(lines)}</svg>')
    # dots, one colour per quest
    for pts, col in groups:
        for (x, y) in pts:
            p.append(dot(x, y + TB, dot_size, col))
    # quest without dots: hollow gold ring at the game's quest area
    p.append(area(RING[0], RING[1] + TB, area_size, title))
    # turn-in badge
    qx, qy = TURNIN
    p.append(turnin_badge(qx, qy + TB))
    # quest givers with a quest this character can take now
    for gx, gy in GIVERS:
        p.append(giver_badge(gx, gy + TB))
    # tooltip on a wolf dot (showGroupTooltip): title in the quest's dot colour
    hx, hy = WOLVES_A[7]
    tip1 = (f'<div style="color:{qc["wolf"]};font-size:15px">[8] {esc(q["wolf"])}</div>'
            f'<div style="color:#edf4f7">&nbsp;&nbsp;{esc(q["wolfObj"])}: 5/8</div>'
            f'<div style="color:#a7b9c5">{esc(L["questObjHint"])}</div>'
            f'<div style="color:#a7b9c5">EzWoW - Quest</div>')
    p.append(f'<div class="tip" style="left:{hx + 14}px;top:{hy + TB - 70}px">{tip1}</div>')
    # tooltip on the quest area ring (no dot colour: gold title)
    rx, ry = RING
    tip3 = (f'<div style="color:{title};font-size:15px">[10] {esc(q["necklace"])}</div>'
            f'<div style="color:#edf4f7">&nbsp;&nbsp;{esc(q["necklaceObj"])}: 0/1</div>'
            f'<div style="color:#a7b9c5">{esc(L["questObjArea"])}</div>'
            f'<div style="color:#a7b9c5">{esc(L["questObjHint"])}</div>'
            f'<div style="color:#a7b9c5">EzWoW - Quest</div>')
    p.append(f'<div class="tip" style="left:{rx + 16}px;top:{ry + TB - 48}px">{tip3}</div>')
    # tooltip on the turn-in mark (QuestLogPins)
    tip2 = (f'<div style="color:#7aa2f7;font-size:15px">{esc(t["npc"])}</div>'
            f'<div style="color:#edf4f7">[7] {esc(q["mine"])}&nbsp;&nbsp;<span style="color:#40ff59">{esc(L["questPinReady"])}</span></div>'
            f'<div style="color:#a7b9c5">{esc(L["questPinHint"])}</div>'
            f'<div style="color:#a7b9c5">EzWoW - Quest</div>')
    p.append(f'<div class="tip" style="right:{w - qx + 14}px;top:{qy + TB + 18}px">{tip2}</div>')
    # tooltip on a quest giver: NPC name, the quests to take now in yellow ("! [Lv] name")
    gx, gy = GIVERS[0]
    tip4 = (f'<div style="color:#7aa2f7;font-size:15px">{esc(t["giver"])}</div>'
            + "".join(f'<div style="color:#ffd100">! [{lv}] {esc(name)}</div>' for lv, name in zip((10, 11), t["gq"]))
            + f'<div style="color:#a7b9c5">{esc(L["questGiverHint"])}</div>'
            f'<div style="color:#a7b9c5">EzWoW - Quest</div>')
    p.append(f'<div class="tip" style="left:{gx + 16}px;top:{gy + TB - 14}px">{tip4}</div>')
    html_ = (f'<div class="abs" style="left:{x0}px;top:{y0}px;width:{w}px;height:{h}px;border:2px solid #5d6d7a;border-radius:6px;'
             f'overflow:hidden;background:#0e1418">' + "".join(p) + "</div>")
    anchors = {
        "dots": (x0 + 30, y0 + TB + 40),
        "ring": (x0 + RING[0] - 30, y0 + TB + RING[1]),
        "turnin": (x0 + qx + 40, y0 + TB + qy),
        "giver": (x0 + GIVERS[1][0] - 34, y0 + TB + GIVERS[1][1]),
    }
    return html_, anchors


def scene(ctx, lang, x0, y0, w, h):
    t, L, pc = T[lang], ctx["L"][lang], ctx["pins"]
    qc = quest_colors(ctx)
    title = hexc(pc["COLOR_TITLE"])
    msize = ctx["pconst"]["MINIMAP_DOT_SIZE"] * DS
    q = t["q"]
    p = []
    # minimap (simplified)
    D = h - 20
    mm = [f'<div class="abs" style="left:10px;top:10px;width:{D}px;height:{D}px;border-radius:50%;overflow:hidden;'
          f'background:radial-gradient(circle at 40% 40%,#6e7f45,#4c5b31);border:5px solid #8c7a55;box-shadow:0 0 0 2px #1a140b">']
    mm.append(f'<svg class="abs" style="left:0;top:0" width="{D}" height="{D}"><path d="M0 {D * .62} Q{D * .5} {D * .55} {D} {D * .7}" '
              f'stroke="#a88f5f" stroke-width="7" fill="none"/></svg>')
    for (mx, my), key in (((.25, .3), "wolf"), ((.36, .2), "wolf"), ((.2, .45), "wolf"), ((.72, .68), "supply"), ((.62, .78), "supply")):
        mm.append(dot(mx * (D - 10), my * (D - 10), msize, qc[key], inset=2))
    # a quest area on the minimap is a larger gold dot (MINIMAP_DOT_SIZE + 4)
    mm.append(dot(.8 * (D - 10), .5 * (D - 10), msize + 4 * DS, title, inset=2))
    mm.append(f'<svg class="abs" style="left:{D / 2 - 5 - 9}px;top:{D / 2 - 5 - 11}px" width="18" height="22" viewBox="0 0 18 22">'
              '<path d="M9 1 L17 20 L9 15 L1 20 Z" fill="#f2f2f2" stroke="#222" stroke-width="1.5"/></svg>')
    mm.append("</div>")
    p.append("".join(mm))
    # party chat
    me = t["me"]
    pre = f'[{t["party"]}] [{me}]: '
    lines = [
        L["QUEST_ANNOUNCE_ACCEPTED"].replace("%s", q["supply"]),
        L["QUEST_ANNOUNCE_PROGRESS"].replace("%s", q["wolf"], 1).replace("%s", f'{q["wolfObj"]}: 5/8', 1),
        L["QUEST_ANNOUNCE_DONE"].replace("%s", q["mine"]),
        L["QUEST_ANNOUNCE_TURNED_IN"].replace("%s", q["letter"]),
    ]
    chat = "<br>".join(f'{esc(pre)}{esc(s)}' for s in lines)
    chat_top = round((h - 4 * 26 - 20) / 2)
    p.append(f'<div class="abs" style="left:{D + 34}px;top:{chat_top}px;width:{w - D - 50}px;background:rgba(0,0,0,.42);padding:10px 14px;'
             f'font-size:16px;line-height:26px;color:#aaaaff;white-space:nowrap;text-shadow:1px 1px 1px #000">{chat}</div>')
    html_ = (f'<div class="abs" style="left:{x0}px;top:{y0}px;width:{w}px;height:{h}px;border:1px solid #2b3a45;border-radius:6px;'
             f'background:linear-gradient(180deg,#1b2a22 0%,#22301f 45%,#2d2a1d 100%);overflow:hidden">' + "".join(p) + "</div>")
    anchors = {"minimap": (x0 - 30, y0 + 10 + D / 2), "chat": (x0 + w - 16, y0 + chat_top)}
    return html_, anchors


def ui_page(lang, ctx):
    global S
    S = 1.6
    t = T[lang]
    ox, oy = 96, 168
    parts = []
    tr_html, ta, (tw, th) = tracker(ctx, lang, ox, oy)
    parts.append(tr_html)
    mx, my, mw, mh = 640, oy, 910, 500
    m_html, ma = map_panel(ctx, lang, mx, my, mw, mh)
    parts.append(m_html)
    sy = my + mh + 24
    sh = 170
    s_html, sa = scene(ctx, lang, mx, sy, mw, sh)
    parts.append(s_html)

    def P(gx, gy):
        return ox + gx * S, oy + gy * S

    lx = ox - 30
    calls = [
        (lx, P(0, 12)[1]),                         # 1 header
        (lx, P(0, ta["zone0"])[1]),                # 2 zone
        (lx, P(0, ta["quest_supply"])[1]),         # 3 item button
        (lx, P(0, ta["quest_bandit"])[1]),         # 4 quest line
        (P(tw, 0)[0] + 30, P(0, ta["obj"])[1]),    # 5 objective colours
        (P(tw, 0)[0] + 30, P(0, th - 8)[1]),       # 6 resize corner
        ma["dots"], ma["ring"], ma["turnin"],       # 7 8 9
        sa["minimap"], sa["chat"],                 # 10 11
        ma["giver"],                               # 12
    ]
    for i, (x, y) in enumerate(calls, 1):
        parts.append(f'<div class="call" style="left:{x - 15:.0f}px;top:{y - 15:.0f}px">{i}</div>')

    notes_top = max(oy + th * S, sy + sh) + 40
    half = 6

    def note_html(start, lst):
        return "".join(f'<div class="note"><span class="n">{start + i}</span><div><b>{esc(a)}</b> — {esc(b)}</div></div>'
                       for i, (a, b) in enumerate(lst))
    parts.append(f'<div class="notes" style="left:50px;top:{notes_top:.0f}px;width:720px">{note_html(1, t["notes"][:half])}</div>')
    parts.append(f'<div class="notes" style="left:820px;top:{notes_top:.0f}px;width:730px">{note_html(half + 1, t["notes"][half:])}</div>')
    nh = max(notes_height(t["notes"][:half], 680), notes_height(t["notes"][half:], 690))
    page_h = notes_top + nh + 70
    parts.append(f'<div class="abs foot" style="left:50px;top:{page_h - 58:.0f}px;width:1500px">{esc(t["foot"])}</div>')
    head = f'<div class="page"><h1>EzWoW - Quest</h1><div class="lead">{esc(t["lead"])}</div></div>'
    return head + "".join(parts), page_h


# ---------------------------------------------------------------------------
# Settings window (UI/OptionsWindow.lua)
# ---------------------------------------------------------------------------
def settings_page(lang, ctx):
    global S
    S = 1.5
    t, L, st, dflt = T[lang], ctx["L"][lang], ctx["ostyle"], ctx["defaults"]
    sections, checks, (W, H) = ctx["options"]
    ox, oy = 60, 160
    p = []
    accent, text_c, sub = css(st["accent"]), css(st["text"]), css(st["textSub"])

    def btn(x, y, w, h, label, size=10.5):
        return box(x, y, w, h, f"background:{css(st['bgSub'])};border:1px solid {css(st['border'])};display:flex;align-items:center;justify-content:center",
                   f'<span class="fit" data-fit="{(w - 8) * S:.1f}" style="font-size:{px(size)};color:{text_c};white-space:nowrap;{SHADOW}">{esc(label)}</span>')

    # header (56 high, inset 1)
    p.append(box(1, 1, W - 2, 56, f"background:{css(st['bgSub'])};border:1px solid {css(st['border'])}"))
    p.append(box(1, 55, W - 2, 2, f"background:{accent}"))
    p.append(f'<img class="abs" src="{ctx["icon"]}" style="left:{px(15)};top:{px(15)};width:{px(28)};height:{px(28)}">')
    p.append(f'<div class="t" style="left:{px(53)};top:{px(14)};font-size:{px(14.5)};color:{text_c};{SHADOW}">{esc(L["ADDON_TITLE"])}'
             f'<span style="font-size:{px(10)};color:{sub};margin-left:{px(8)}">v{esc(ctx["version"])}</span></div>')
    p.append(f'<div class="t" style="left:{px(53)};top:{px(32.5)};font-size:{px(10)};color:{sub};{SHADOW}">{esc(L["ADDON_SUBTITLE"])}</div>')
    p.append(btn(W - 1 - 12 - 24, 1 + 16, 24, 24, "X", 11))
    # language
    p.append(f'<div class="t" style="left:{px(20)};top:{px(70)};font-size:{px(11)};color:{sub};{SHADOW}">{esc(L["OPT_LANGUAGE"])}</div>')
    lw = 32 if lang == "ko" else 52
    p.append(btn(20 + lw + 12, 70 + 6 - 11, 160, 22, "Auto  ▾"))

    # sections
    sec_title = {"secTracker": "SECTION_TRACKER", "secQuest": "SECTION_QUEST_AUTO", "secMap": "SECTION_MAP"}
    for name, y in sections.items():
        yy = -y
        p.append(box(18, yy + 3, 3, 14, f"background:{accent}"))
        p.append(f'<div class="t" style="left:{px(28)};top:{px(yy + 10)};transform:translate(0,-50%);font-size:{px(12.5)};color:{accent};{SHADOW}">'
                 f'<span id="sec_{name}">{esc(L[sec_title[name]])}</span></div>')
        p.append(f'<div class="abs sline" data-sec="sec_{name}" style="top:{px(yy + 10)};right:{px(18)};height:1px;background:{css(st["border"], .65)}"></div>')

    # check boxes with default states (Map Finder present, tracker on)
    for name, c in checks.items():
        if name.startswith("_"):
            continue
        val = dflt.get(c["field"])
        on = (val is not False) if c["op"] == "~= false" else (val is True)
        x, y, w = c["x"], -c["y"], c["w"]
        fill = box(3, 3, 10, 10, f"background:{accent}") if on else ""
        p.append(box(x, y + 2, 18, 18, f"background:{css(st['bgSub'])};border:1px solid {accent if on else css(st['border'])}", fill))
        p.append(f'<div class="t" style="left:{px(x + 27)};top:{px(y + 11)};transform:translate(0,-50%);font-size:{px(10.5)};color:{text_c};{SHADOW}">'
                 f'<span class="fit" data-fit="{(w - 27) * S:.1f}" data-min="{10.5 * 0.7 * S:.1f}">{esc(L[c["label"]])}</span></div>')

    # footer (40 high)
    fy = H - 1 - 40
    p.append(box(1, fy, W - 2, 40, f"background:{css(st['bgSub'])};border:1px solid {css(st['border'])}"))
    b = checks["_buttons"]
    p.append(btn(1 + 14, fy + 8, 136, 24, L[b["btnDefaults"]]))
    p.append(btn(W - 1 - 14 - 176, fy + 8, 176, 24, L[b["btnResetTracker"]]))
    p.append(f'<div class="t" style="left:{px(W / 2)};top:{px(fy + 20)};transform:translate(-50%,-50%);font-size:{px(10.5)};color:{sub};{SHADOW}">{esc(L["HINT_FOOTER"])}</div>')

    win = (f'<div class="abs" id="win" style="left:{ox}px;top:{oy}px;width:{px(W)};height:{px(H)};background:{css(st["bgMain"])};'
           f'border:1px solid {css(st["border"])}">' + "".join(p) + "</div>")
    ys = sorted(-y for y in sections.values())
    spans = [(64, 92), (ys[0], ys[1]), (ys[1], ys[2]), (ys[2], H - 41 - 30), (H - 41, H)]
    calls = "".join(f'<div class="call" style="left:{ox + W * S + 18:.0f}px;top:{oy + (a + b_) / 2 * S - 15:.0f}px">{i}</div>'
                    for i, (a, b_) in enumerate(spans, 1))
    notes = "".join(f'<div class="note"><span class="n">{i}</span><div><b>{esc(a)}</b> — {esc(b_)}</div></div>'
                    for i, (a, b_) in enumerate(t["sNotes"], 1))
    page_h = oy + H * S + 80
    nx = ox + W * S + 80
    # section lines start 10 px right of the title text
    js = ("<script>document.querySelectorAll('.sline').forEach(function(l){var s=document.getElementById(l.dataset.sec);"
          "var w=document.getElementById('win').getBoundingClientRect();var r=s.getBoundingClientRect();"
          f"l.style.left=(r.right-w.left+{10 * S})+'px';}});</script>")
    body = (f'<div class="page"><h1>EzWoW - Quest <span class="badge">{esc(t["sTitle"])}</span></h1>'
            f'<div class="lead">{esc(t["sLead"])}</div></div>' + win + calls
            + f'<div class="notes" style="left:{nx:.0f}px;top:{oy + 10}px;width:{PAGE_W - nx - 50:.0f}px">{notes}</div>'
            + f'<div class="abs foot" style="left:50px;top:{page_h - 44:.0f}px">{esc(t["sFoot"])}</div>' + js)
    return body, page_h


# ---------------------------------------------------------------------------
def find_chrome():
    cands = [os.environ.get("CHROME"), r"C:\Program Files\Google\Chrome\Application\chrome.exe",
             r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
             shutil.which("chrome"), shutil.which("google-chrome"), shutil.which("chromium")]
    for c in cands:
        if c and Path(c).exists():
            return c
    sys.exit("Chrome not found (set CHROME=<path to chrome>)")


def render(chrome, html_text, out_png, height, tmp):
    page = Path(tmp) / (out_png.stem + ".html")
    page.write_text(html_text, encoding="utf-8")
    subprocess.run([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                    f"--user-data-dir={Path(tmp) / 'chrome_profile'}", f"--window-size={PAGE_W},{int(height)}",
                    "--virtual-time-budget=2000", f"--screenshot={out_png}", page.as_uri()],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)


def main(root: Path):
    out = root / "docs" / "images"
    out.mkdir(parents=True, exist_ok=True)
    tracker_src = read(root, "UI/QuestTracker.lua")
    options_src = read(root, "UI/OptionsWindow.lua")
    pins_src = read(root, "Modules/QuestObjectivePins.lua")
    locales = read(root, "Core/Locales.lua")
    ctx = {
        "tstyle": parse_style(tracker_src),
        "tconst": parse_consts(tracker_src),
        "phex": parse_party_hex(tracker_src),
        "ostyle": parse_style(options_src),
        "options": parse_options(options_src),
        "pins": parse_colors(pins_src),
        "qcolors": parse_quest_colors(pins_src),
        "pconst": parse_consts(pins_src),
        "defaults": parse_defaults(read(root, "Core/Init.lua")),
        "L": {"ko": parse_locale(locales, "lKokr"), "en": parse_locale(locales, "lEnus")},
        "version": parse_version(read(root, "EzWoW-Quest.toc")),
        "icon": "data:image/png;base64," + base64.b64encode((root / "Media" / "Icon.png").read_bytes()).decode(),
    }
    chrome = find_chrome()
    tmp = tempfile.mkdtemp(prefix="ezq_readme_")
    try:
        for lang in ("ko", "en"):
            for name, fn in (("ui", ui_page), ("settings", settings_page)):
                body, h = fn(lang, ctx)
                html_text = (f'<!doctype html><html><head><meta charset="utf-8"><style>{CSS}</style></head>'
                             f'<body style="height:{int(h)}px">{body}{FIT_JS}</body></html>')
                png = out / f"{name}_{lang}.png"
                render(chrome, html_text, png, h, tmp)
                print("wrote", png, int(h))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve())
