# EzWoW - Quest (`EzWoW-Quest`)

## CurseForge

- **Project ID / 프로젝트 ID:** `0` (not created yet / 아직 만들지 않음)
- **Project page / 프로젝트 페이지:** EzWoW-Quest (link added after the project is created / 프로젝트를 만든 뒤 추가)

**[한국어](#한국어) · [English](#english)**

WoW Forever (`Interface: 16001`) · `/ezq` · `/퀘스트`

---

## 한국어

### 개요

퀘스트에 필요한 기능을 한곳에 모은 애드온입니다.

- 기본 추적창 대신 쓰는 **스크롤형 퀘스트 추적기** (지역별 묶음, `[레벨]` 난이도 색, 목표 진행 색, 퀘스트 아이템 버튼)
- **자동 수락·자동 완료** (Shift를 누르고 대화하면 건너뜀), 판매가가 가장 높은 보상 표시
- 수락·진행·완료를 파티에 알리는 **파티 진행 알림**
- **지도와 미니맵의 퀘스트 표시**: 처치할 몬스터(빨간 점), 모을 대상(금색 점), 퀘스트 지역(금색 고리), 보고 위치(노란 `?`)

### 화면 미리보기

![퀘스트 추적기와 지도 표시](docs/images/ui_ko.png)

![설정창](docs/images/settings_ko.png)

> 이미지는 애드온 코드의 창 크기·좌표·색상·문구로 재현한 **예시 화면**입니다. 지도·미니맵·아이콘은 단순화한 그림이고, 퀘스트·NPC·캐릭터 이름은 지어낸 예시입니다.

### 설치

1. `EzWoW-Quest` 폴더를 `Interface/AddOns/` 폴더에 넣습니다.
2. 캐릭터 선택 화면의 **애드온** 목록에서 켭니다.
3. 지도 표시를 쓰려면 **EzWoW - Map Finder**도 함께 켭니다.
4. 게임에서 `/ezq`(또는 `/퀘스트`)로 설정창을 엽니다.

### 기능 (위 그림의 번호)

| 번호 | 기능 | 설명 |
|---|---|---|
| ① | 추적기 머리줄 | 수행 중인 퀘스트 수/최대 수. 좌클릭: 목록 접기·펼치기, 우클릭: 설정창 |
| ② | 지역 헤더 | 퀘스트를 지역별로 묶습니다. 클릭하면 그 지역을 접습니다 |
| ③ | 퀘스트 아이템 버튼 | 사용 아이템이 있는 퀘스트는 왼쪽 버튼을 눌러 바로 씁니다 |
| ④ | 퀘스트 줄 | `[레벨]`을 난이도 색으로, `(완료)`·`(실패)`를 바로 표시합니다 |
| ⑤ | 목표 진행 색 | 0이면 흰색, 진행할수록 주황 → 노랑 → 연두, 다 채우면 초록 |
| ⑥ | 크기 조절 | 아래 모서리를 끌어 가로·세로 크기 조절(기본 270×360) |
| ⑦ | 처치 대상 (빨간 점) | 목표 몬스터가 있는 자리. 가까운 점은 가는 선으로 이어 사냥터 범위를 보여 줍니다 |
| ⑧ | 수집 대상 (금색 점) · 퀘스트 지역 (금색 고리) | 모으거나 사용할 오브젝트·아이템의 자리와 게임이 알려 주는 퀘스트 지역 |
| ⑨ | 보고 위치 (노란 `?`) | 목표를 다 채운 퀘스트를 주거나 받는 NPC. 옵션을 켜면 진행 중인 퀘스트도 회색 `?`로 표시 |
| ⑩ | 미니맵 | 가까운 목표 점과 퀘스트 지역을 미니맵에도 표시 |
| ⑪ | 파티 진행 알림 | 파티(인스턴스 그룹)에 수락·목표 진행·목표 달성·완료를 알림. 공격대에서는 보내지 않음 |

지도의 점·물음표에 마우스를 올리면 퀘스트와 목표가 나오고, 클릭하면 그 자리에 웨이포인트를 찍습니다.

#### 추적기 조작

| 조작 | 결과 |
|---|---|
| 머리줄 좌클릭 / 우클릭 | 목록 접기·펼치기 / 설정창 열기 |
| 퀘스트 좌클릭 | 그 퀘스트의 퀘스트 로그 열기 |
| Ctrl + 좌클릭 | 집중 추적(`▸`) 켜기·끄기 |
| Shift + 좌클릭 | 채팅창에 퀘스트 링크 / 추적 해제 |
| 퀘스트 우클릭 | 목표 접기·펼치기 |
| Alt + 우클릭 | 목록에서 숨기기 |
| 끌기 | 추적기 이동 |
| Ctrl + 마우스 휠 | 크기 50~150% |
| 마우스 휠 | 긴 목록 스크롤 |
| 아래 모서리 끌기 / 우클릭 | 크기 조절 / 기본 크기(270×360) |
| Shift + 우클릭 | 위치 초기화 |
| Ctrl + 우클릭 | 크기(100%, 270×360) 초기화 |
| Ctrl + Alt + 우클릭 | 위치·크기 모두 초기화 |

- 전투 중에는 보호된 창 속성을 바꾸지 않습니다. 퀘스트 아이템 버튼은 전투가 끝난 뒤 갱신됩니다.

### 퀘스트 자동화

설정창의 **퀘스트 자동화** 항목에서 켭니다. NPC와 대화할 때 **Shift**를 누르고 있으면 그 대화에서는 자동화가 동작하지 않습니다.

| 항목 | 설명 | 기본값 |
|---|---|---|
| 퀘스트 자동 수락 | 퀘스트를 바로 수락합니다. 퀘스트가 없고 대화 선택지가 하나뿐인 NPC는 그 선택지를 고릅니다(귀환 장소 설정·초기화 같은 선택지는 제외). 일행이 공유한 퀘스트·호위 퀘스트 확인 창도 수락합니다. | 끔 |
| 완료한 퀘스트 자동 완료 | 목표를 다 채운 퀘스트를 바로 완료합니다. 보상을 골라야 하면 직접 고릅니다. 골드를 내는 퀘스트는 완료하지 않습니다. | 끔 |
| 반복·회색 퀘스트 제외 | 반복·일일 퀘스트와 레벨이 낮은 회색 퀘스트는 자동 수락하지 않습니다. | 켬 |
| 아이템을 내는 퀘스트는 자동 완료 안 함 | 아이템을 건네야 하는 퀘스트는 직접 완료합니다. | 끔 |
| 판매가가 가장 높은 보상 표시 | 보상을 고를 때 상점 판매가가 가장 높은 아이템에 금화 표시를 붙입니다. | 켬 |
| 퀘스트 진행을 파티에 알리기 | 파티(인스턴스 그룹)에 수락·목표 진행·목표 달성·완료를 알립니다. 공격대에서는 보내지 않습니다. | 켬 |

### 설정창 (`/ezq`)

| 번호 | 항목 | 기본값 |
|---|---|---|
| ① | 언어 (자동 + 8개 언어) | 자동 |
| ② | EzWoW 퀘스트 추적기 사용 (끄면 게임 기본 추적창) · 끄면 아래 추적기 옵션은 비활성화 | 켬 |
| ② | 기본 게임의 우측 퀘스트 추적창 숨기기 | 켬 |
| ② | 수행 중인 모든 퀘스트 자동 표시 (끄면 추적 체크한 퀘스트만) | 켬 |
| ② | 지역·분류 헤더 및 퀘스트 레벨(`[레벨]`) 난이도 색상 표시 | 켬 |
| ② | 퀘스트 목록 반투명 배경 패널 상시 표시 | 켬 |
| ③ | 퀘스트 자동화 (위 표 참고) | - |
| ④ | 완료한 퀘스트의 보고 위치를 지도에 표시 | 켬 |
| ④ | 진행 중인 퀘스트 위치도 표시 | 끔 |
| ④ | 진행 중인 퀘스트 목표 위치 표시 (지도·미니맵) | 켬 |
| ⑤ | 설정 기본값 복원(언어와 모아 둔 퀘스트 정보는 유지) · 추적기 위치·크기 초기화 | - |

- ④ 항목은 **EzWoW - Map Finder**가 없으면 흐려지고 안내 문구가 나옵니다.

### 명령어 (`/ezq`, `/퀘스트`)

| 명령어 | 설명 |
|---|---|
| `/ezq` | 설정창 열기/닫기 |
| `/ezq reset` (`/퀘스트 초기화`) | 추적기 위치·크기 초기화 |
| `/ezq help` (`/퀘스트 도움말`) | 명령어 안내 |

### 다른 EzWoW 애드온과 함께 쓰기

- **EzWoW - Frame Mover**와 **EzWoW - Map Finder**에 있던 퀘스트 기능(추적기, 자동화, 파티 알림, 지도의 퀘스트 표시)이 이 애드온으로 옮겨 왔습니다. 이 애드온이 켜져 있으면 두 애드온의 퀘스트 기능은 저절로 꺼지고, 이 애드온이 맡습니다. 이 애드온을 끄면 예전처럼 두 애드온이 퀘스트 기능을 맡습니다.
- 처음 실행할 때 두 애드온의 퀘스트 설정(추적기 크기·위치·접힘·숨긴 퀘스트, 자동화, 지도 표시 옵션)을 **한 번만** 그대로 가져오고 채팅창에 알려 줍니다.
- 지도·미니맵 표시는 **EzWoW - Map Finder**의 위치 정보를 쓰므로, 지도 표시를 쓰려면 Map Finder가 함께 켜져 있어야 합니다. 추적기·자동화·파티 알림은 이 애드온만으로 동작합니다.

### 저장 데이터

- `EzWoW_QuestDB`: 설정, 추적기 위치·크기·접힘·숨긴 퀘스트, 게임 중에 알아낸 퀘스트 정보(아이템을 떨어뜨리는 몬스터 등).

---

## English

### Overview

All quest features in one addon.

- A **scrollable quest tracker** that replaces the default one (grouped by zone, difficulty-coloured `[Lv]`, objective progress colours, quest item buttons)
- **Auto accept and auto turn-in** (hold Shift while talking to skip), plus a mark on the reward that sells for most
- **Party progress messages** for accepted, progressed and finished quests
- **Quest marks on the map and minimap**: creatures to kill (red dots), things to collect (gold dots), quest areas (gold ring) and turn-in spots (yellow `?`)

### Screenshots

![Quest tracker and map marks](docs/images/ui_en.png)

![Settings window](docs/images/settings_en.png)

> These are **mock-ups** rebuilt from the window sizes, coordinates, colours and strings in the code. The map, minimap and icons are simplified drawings; quests, NPCs and character names are made up.

### Installation

1. Copy the `EzWoW-Quest` folder into `Interface/AddOns/`.
2. Enable it in the **AddOns** list on the character select screen.
3. For the map marks, enable **EzWoW - Map Finder** as well.
4. Open the settings in game with `/ezq` (or `/퀘스트`).

### Features (numbers in the picture)

| No. | Feature | Description |
|---|---|---|
| ① | Tracker header | Active quests / maximum. Left-click: collapse or expand, right-click: settings |
| ② | Zone header | Quests are grouped by zone. Click a zone to collapse it |
| ③ | Quest item button | Quests with a usable item get a button on the left; click it to use the item |
| ④ | Quest line | `[Lv]` in difficulty colour, `(Complete)` and `(Failed)` at once |
| ⑤ | Objective colours | White at 0, then orange → yellow → light green, green when done |
| ⑥ | Resize | Drag the bottom corner to resize (default 270×360) |
| ⑦ | Kill targets (red dots) | Where the creatures of an objective are. Nearby dots are joined by thin lines so a hunting ground reads as one area |
| ⑧ | Collect targets (gold dots) · quest area (gold ring) | Where the objects and items to collect or use are, and the game's own quest area |
| ⑨ | Turn-in spots (yellow `?`) | Quest giver or turn-in NPC of quests whose objectives are done. An option also shows quests in progress with a grey `?` |
| ⑩ | Minimap | Nearby objective dots and quest areas show on the minimap too |
| ⑪ | Party progress messages | Tells your party (or instance group) about accepted quests, progress, finished objectives and turn-ins. Never sent in a raid |

Hover a dot or question mark on the map to see the quest and objective; click it to set a waypoint there.

#### Tracker controls

| Action | Result |
|---|---|
| Header left-click / right-click | Collapse or expand the list / open settings |
| Quest left-click | Open that quest in the quest log |
| Ctrl + left-click | Focus the quest (`▸`) on or off |
| Shift + left-click | Link in chat / stop tracking |
| Quest right-click | Fold or unfold its objectives |
| Alt + right-click | Hide it from the list |
| Drag | Move the tracker |
| Ctrl + mouse wheel | Scale 50–150% |
| Mouse wheel | Scroll long lists |
| Drag the bottom corner / right-click it | Resize / default size (270×360) |
| Shift + right-click | Reset the position |
| Ctrl + right-click | Reset the scale and size (100%, 270×360) |
| Ctrl + Alt + right-click | Reset both position and size |

- Protected frame attributes are never changed in combat. Quest item buttons are updated after combat.

### Quest automation

Turn it on in the **Quest automation** section of the settings. Hold **Shift** while talking to an NPC to skip automation for that conversation.

| Option | Description | Default |
|---|---|---|
| Auto accept quests | Accepts quests right away. An NPC with no quests and only one dialogue option gets that option picked (hearthstone binding and reset-type options are skipped). Shared and escort quest confirmations are accepted too. | Off |
| Auto turn in finished quests | Turns in completed quests. If you must choose a reward you pick it yourself. Quests that cost gold are never turned in. | Off |
| Skip repeatable and grey quests | Repeatable/daily and low-level grey quests are not auto accepted. | On |
| Do not auto turn in quests that take items | Quests that take items from you are left for you to turn in. | Off |
| Mark the reward that sells for most | Puts a gold mark on the reward choice with the highest vendor price. | On |
| Announce quest progress to party | Tells your party (or instance group) about accepted quests, progress, finished objectives and turn-ins. Never sent in a raid. | On |

### Settings window (`/ezq`)

| No. | Option | Default |
|---|---|---|
| ① | Language (Auto + 8 languages) | Auto |
| ② | Use EzWoW quest tracker (off = game default tracker) · tracker options below are disabled while off | On |
| ② | Hide default game objective tracker | On |
| ② | Automatically show all active quests (off = watched quests only) | On |
| ② | Show zone headers and difficulty-colored quest levels (`[Lv]`) | On |
| ② | Always show translucent background panel behind quest list | On |
| ③ | Quest automation (see the table above) | - |
| ④ | Show turn-in spots of finished quests on the map | On |
| ④ | Also show spots of quests still in progress | Off |
| ④ | Show objective spots of quests in progress (map and minimap) | On |
| ⑤ | Restore Defaults (keeps the language and the learned quest data) · Reset tracker position & size | - |

- The ④ options are dimmed, with a note, when **EzWoW - Map Finder** is not enabled.

### Slash commands (`/ezq`, `/퀘스트`)

| Command | Description |
|---|---|
| `/ezq` | Open/close settings |
| `/ezq reset` | Reset the tracker position and size |
| `/ezq help` | List the commands |

### Working with other EzWoW addons

- The quest features of **EzWoW - Frame Mover** and **EzWoW - Map Finder** (tracker, automation, party messages, quest marks on the map) have moved here. While this addon is enabled, their quest features turn themselves off and this addon takes over. Disable this addon and the two addons handle quests as before.
- On the first start, the quest settings of both addons (tracker size, position, folded and hidden quests, automation, map mark options) are carried over **once**, with a note in chat.
- The map and minimap marks use the location data of **EzWoW - Map Finder**, so it must be enabled for them. The tracker, automation and party messages work on their own.

### Saved data

- `EzWoW_QuestDB`: settings, tracker position, size, folded and hidden quests, and quest data learned while playing (such as which creatures drop quest items).

