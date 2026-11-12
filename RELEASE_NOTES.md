# v1.0.14

### 한국어
- 퀘스트를 주는 NPC 표시를 바로잡았습니다. 아이템으로 시작하는 퀘스트가 완료하는 NPC에게 주는 퀘스트로 보이던 문제와, 종족·직업 전용 퀘스트, 빠져 있던 앞 단계 퀘스트 조건을 고쳤습니다.
- 앞 단계가 필요한 퀘스트는 회색 [선행], 평판처럼 미리 확인할 수 없는 조건이 있는 퀘스트는 회색 [조건]으로 표시합니다. 전문기술 숙련도가 모자라면 "숙련도 N부터"를 표시합니다.
- NPC에게 말을 걸면 실제로 주는 퀘스트와 비교해, 주지 않는 퀘스트는 숨깁니다. 이 정보는 다른 EzWoW 사용자와 공유되어, 데이터에 없는 퀘스트와 NPC도 지도에 표시됩니다.

### English
- Fixed quest givers: quests that start from an item no longer show as given by the NPC you turn them in to, and race- and class-only quests and missing earlier quests are handled.
- Quests that need an earlier quest are shown in grey as [Prereq.], and quests with a requirement that can't be checked (such as reputation) in grey as [Cond.]. A low profession rank shows "skill N+".
- Talking to an NPC compares with the quests it really offers and hides the ones it doesn't. This is shared with other EzWoW users, so quests and NPCs missing from the data also show on the map.
