# v1.0.25

### 한국어
- 경험치 창을 추가했습니다(Ctrl + 끌기로 이동, Ctrl + 휠로 크기). 완료한 퀘스트를 보고하면 얻는 경험치, 휴식 경험치, 시간당 경험치, 레벨업까지 남은 시간과 몹 수를 실시간으로 보여 줍니다.
- 추적창의 퀘스트 줄과 지도의 퀘스트 표시에 퀘스트별 경험치가 나옵니다.
- 완료한 퀘스트만 보고해도 레벨업이면 알려 주고, 레벨업하면 그 레벨에 걸린 시간과 퀘스트·사냥 경험치를 채팅에 요약합니다.
- `/ezq xp`로 경험치 요약을 채팅에 출력합니다.
- 퀘스트를 눌러 길 안내를 하면 화살표와 채팅에 퀘스트 이름이 두 번 나오던 것을, 가는 곳의 NPC·몬스터·아이템 이름이 나오게 고쳤습니다. 지도의 목표 점을 눌러도 목표 이름이 붙습니다.
- 툴팁의 공유 기록 줄(판매·드롭·희귀 목격)을 끌 수 있습니다: `/ezshare tooltip off` 또는 공유 창(`/ezshare`)의 "툴팁 줄" 버튼.
- 게임패드: 아이템에서 X(오른쪽 클릭)로 아이템을 쓰면 "애드온으로 인해 인터페이스 작동이 실패했습니다"가 뜨며 쓰이지 않던 문제와, View 버튼으로 화면의 EzWoW 요소(퀘스트 목록·유틸리티바 등)를 고르지 못하던 문제를 고쳤습니다.
- 게임패드: 지도의 퀘스트 표시에 커서를 올려도 툴팁이 나오지 않던 문제를 고쳤습니다. 경험치 창은 View 버튼으로 고를 수 있습니다.
- 게임패드: 게임이 숫자(1 2 3 4)로 보여 주는 패드도 제조사(소니·마이크로소프트·닌텐도)를 알아보고 EzWoW 패드 안내에 맞는 버튼 그림을 보여 줍니다.

### English
- Added an experience window (Ctrl + drag to move, Ctrl + wheel to resize). It shows, live, the XP your completed quests will give, rested XP, XP per hour, and the time and kills left to the next level.
- Quest lines in the tracker and quest marks on the map now show each quest's XP.
- You are told when turning in your completed quests is enough to level up, and on level-up a chat summary lists the time the level took and its quest and kill XP.
- `/ezq xp` prints an XP summary in chat.
- Guiding to a quest no longer shows the quest name twice on the arrow and in chat; it names the NPC, monster or item you are guided to. Clicking an objective dot on the map adds the objective's name too.
- Shared lines on tooltips (sold by, drops, rare sightings) can be turned off with `/ezshare tooltip off` or the "Tooltip lines" button in the sharing window (`/ezshare`).
- Gamepad: fixed "Interface action failed because of an AddOn" when using an item with X (right-click), and the View button reaches the EzWoW frames on screen (quest list, utility bar...) again.
- Gamepad: quest marks on the map show their tooltip under the cursor, and the experience window can be reached with the View button.
- Gamepad: for pads the game shows with numbers (1 2 3 4), the EzWoW key guide now shows the maker's button pictures (Sony, Microsoft, Nintendo).
