# v1.0.24

### 한국어
- 지도에 한 퀘스트의 목표 위치 점이 좁은 곳에 몰려 있으면 서로 붙지 않게 묶어서 보여 줍니다(마우스를 올리면 묶인 자리를 펼쳐 보여 줌).
- 지도에서 마지막으로 마우스를 올린 핀이 마우스를 떼도 다른 모든 EzWoW 핀(퀘스트·던전·비행·낚시 등) 위에 남습니다. 다른 핀에 올리면 그 핀이 맨 위로 옵니다. 지도가 다시 그려진 뒤에도 같은 핀이 다시 올라옵니다.
- 퀘스트 목록의 "모두 체크"가 한도를 너무 낮게 기억해, 더 체크할 수 있는데도 "모두 해제"로 바뀌던 문제를 고쳤습니다.
- 게임은 퀘스트를 20개까지만 추적 체크하지만, 그 이상 체크한 퀘스트도 EzWoW 퀘스트 추적창에 모두 나옵니다(예전에는 20개를 넘긴 퀘스트가 추적창에서 숨겨졌음).
- 퀘스트 추적창 머리말에 지금 목록에 들어 있는 퀘스트 수("목록 N")를 따로 보여 줍니다.
- 퀘스트 목록 옆 "모두 펼치기·접기", "모두 체크·해제" 버튼에 마우스를 올리면 하는 일과 애드온 이름이 나옵니다.
- 퀘스트를 주는 NPC가 여럿일 때 이전 NPC가 다른 후보 목록에서 빠지던 문제를 고쳤습니다.
- 공유 기록 저장 데이터가 오래 쓰면 조금씩 커지던 문제를 고쳤습니다.

### English
- Quest objective dots crowded in a small area are grouped so they no longer touch (hovering one shows the spots it stands for).
- The map pin you hovered last stays in front of all other EzWoW pins (quests, dungeons, flights, fishing…) after the mouse leaves, until you hover another one. It also comes to the front again after the map is redrawn.
- Fixed "Check all" in the quest list remembering too low a limit and turning into "Uncheck all" while more quests could still be checked.
- The game watches at most 20 quests, but every quest you check now stays in the EzWoW quest tracker (quests past 20 used to be hidden from it).
- The quest tracker header now also shows how many quests are in its list ("listed N").
- Hovering the "Expand/Collapse all" and "Check/Clear all" buttons next to the quest list shows what they do and the addon's name.
- Fixed the previous quest giver dropping out of the other givers list when a quest has several.
- Fixed shared-record save data slowly growing over long use.
