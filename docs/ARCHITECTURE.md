# 아키텍처

## 신뢰 경계

```
클라이언트                         │ 서버
───────────────────────────────────┼──────────────────────────────────────────
입력 (어느 손, 어느 방향)          │ 검증 → 타겟팅 → 힘 적용
표시용 타이머 보간                 │ 실제 시간 측정
스테이지 목록의 잠금 아이콘        │ 실제 해금 판정
메달 색상 렌더링                   │ 메달 결정
빔·트레일 이펙트                   │ 무엇이 실제로 일어났는지
```

클라이언트에는 게임 판정이 하나도 없다. 화면에 보이는 모든 수치는 서버가 보낸 값이거나 서버가
보낸 값으로부터 보간한 값이다. 자세한 근거는 [`ANTI_CHEAT.md`](ANTI_CHEAT.md).

---

## 부팅 순서

`src/server/init.server.luau`. 순서가 중요한 지점이 세 곳 있다.

```
1. Players.CharacterAutoLoads = false     ← 누가 접속하기 전에
2. 콜리전 그룹 등록                        ← StageBuilder가 파트에 그룹을 지정하기 전에
3. DataService                            ← 프로필을 읽는 모든 것보다 먼저
   MonetizationService
4. 태그 기반 시스템들                      ← 월드가 생기기 전에 (added-signal 수신)
   MagnetService / EnemyService / CombatService
   PuzzleService / GateService / HazardService
5. 런 시스템                              ← RunSessionService, RecordService
6. 서비스 간 배선                          ← 자석 훅, 체크포인트 저장 패스
7. StageService                           ← 월드 구축
8. RespawnService                         ← 허브 SpawnLocation이 존재한 뒤에 스폰 시작
```

4단계가 7단계보다 앞서는 이유: 모든 태그 기반 시스템은
`CollectionService:GetInstanceAddedSignal`로 등록한다. 월드보다 먼저 구독해 두면 스테이지가
빌드되는 동안 자동으로 전부 잡히고, 나중에 재스캔할 필요가 없다.

---

## 서비스 의존 관계

```
                         ┌──────────────┐
                         │ DataService  │
                         └──────┬───────┘
                    ┌───────────┼────────────┐
                    ▼           ▼            ▼
            ┌──────────────┐ ┌────────┐ ┌──────────────┐
            │RecordService │ │Entitle-│ │ StageService │
            └──────┬───────┘ │ ments  │ └──────┬───────┘
                   │         └───┬────┘        │
                   ▼             ▼             ▼
        ┌────────────────────┐ ┌──────────┐ ┌──────────────┐
        │ LeaderboardService │ │Monetiza- │ │ StageBuilder │
        └────────────────────┘ │  tion    │ └──────────────┘
                               └──────────┘
        ┌────────────────────┐
        │ RunSessionService  │──▶ MovementAudit
        └─────────┬──────────┘
                  │ (Signal)
                  ▼
            RecordService, StageService

        ┌────────────────────┐
        │   MagnetService    │──▶ MagneticRegistry, ClingController
        └────────────────────┘
                  ▲ hooks (부팅 시 주입)
                  └── RunSessionService.GetActiveStageId
                      MovementAudit.NoteBoost
```

`MagnetService`가 런 시스템을 직접 `require`하지 않는 이유는 순환 참조 회피다. 대신
`SetHooks()`로 두 함수만 주입받는다. 나머지 서비스 간 통신은 `Signal`을 쓴다 —
`RunSessionService.Finished`를 `RecordService`가 듣고, `EnemyService.GroupCleared`와
`PuzzleService.GroupCompleted`를 `GateService`가 듣는 식이다.

---

## 주행 한 번의 데이터 흐름

```
플레이어가 출발 볼륨에 들어감
  └─ RunSessionService.scanTriggers (20 Hz 오버랩 질의)
       └─ startRun
            ├─ MovementAudit.Begin
            ├─ Net.RunUpdate → 클라이언트 (kind = "Started")
            └─ Signal Started
                 └─ RecordService  : attempts += 1
                 └─ StageService   : 아무도 안 달리고 있으면 스테이지 초기화

주행 중
  ├─ MovementAudit.Sample     (10 Hz)  위치 표본 → 위반 집계
  ├─ syncTimers               (2 Hz)   권위 있는 경과 시간 전송
  └─ MagnetService            (입력마다) NoteBoost로 부스트 창 갱신

체크포인트 통과
  └─ reachCheckpoint : 순서 확인 → 구간 기록 → 리스폰 지점 갱신

도착 볼륨
  └─ finishRun
       ├─ MovementAudit.Finish → 판정
       ├─ validate()  체크포인트 / 최소시간 / 구간 / 이동 감사
       └─ Signal Finished (valid 포함)
            └─ RecordService
                 ├─ valid == false → 저장하지 않음 (이미 클라이언트에 사유 전송됨)
                 └─ valid == true
                      ├─ 프로필의 개인 기록·메달 갱신
                      ├─ LeaderboardService.Submit (개인 신기록일 때만)
                      ├─ DataService.Save (즉시)
                      └─ Net.RunUpdate → 메달 팝업
```

---

## 랭킹 저장 구조

스테이지마다 OrderedDataStore 하나: `StageTimes_v1_<stageId>`, 키는 유저 ID, 값은 밀리초 정수.
오름차순 정렬이 곧 빠른 순이다.

이 한 가지 선택이 단계별 출시를 가능하게 한다.

| 필요 | 연산 | 상태 |
| --- | --- | --- |
| 개인 최고 기록 | 프로필에서 직접 읽기 | 동작 중 |
| 친구 랭킹 | 친구 목록 → 같은 스토어의 키별 `GetAsync` | 동작 중 |
| 글로벌 Top 10 | 같은 스토어에 `GetSortedAsync(true, 10)` | **읽기만 잠금** |

글로벌은 마이그레이션도 백필도 필요 없다. `GameConfig.Features.GlobalLeaderboard`를 켜는 것이
전부다. 쓰기 경로는 처음부터 동작하므로 플래그를 켜는 시점에 데이터가 이미 쌓여 있다.

랭킹판 UI도 이에 맞춰져 있다. 글로벌 탭은 지금도 보이고 선택되며, 서버가 `unavailableReason`을
돌려주면 그 문구를 그대로 표시한다. 2차 작업은 서버 플래그 하나이고 클라이언트 변경은 없다.

### 프로필 스키마

`DataService.SCHEMA_VERSION` + `migrations` 테이블. 나중에 필드를 추가하는 것은 덧붙이기이지
초기화가 아니다. 마이그레이션 경로가 없으면 데이터를 지우는 대신 경고하고 현재 버전으로
표시한다 — 마이그레이션 누락 때문에 플레이어 기록을 날리는 것이 더 나쁘다.

동시 쓰기는 `UpdateAsync`로 병합하며, 병합 규칙은 "더 빠른 기록이 이긴다"이다. 텔레포트 등으로
두 서버가 잠깐 같은 플레이어를 들고 있어도 개인 신기록이 유실되지 않는다.

---

## 자석 메카닉의 두 갈래

`MagneticRegistry.IsImmovable()`이 힘의 방향을 결정한다.

```
                   대상이 고정되어 있거나 매우 무거운가?
                          │
             ┌────────────┴────────────┐
            아니오                     예
             │                          │
       물체가 날아간다              플레이어가 움직인다
       (전투 / 퍼즐)                 (이동)
             │                          │
    ApplyImpulse                 Pull  → 그래플 → 도착 시 벽 붙기
    (질량 비례, 상한 존재)        Push  → 반작용 발사
```

즉 "이동"과 "전투"가 별개 시스템이 아니라 같은 힘의 두 결과다. 무게 처리도 마찬가지다 — 무거운
물체와 가벼운 물체에 같은 뉴턴을 주고 임펄스에 상한을 두면, 무거운 것이 덜 움직인다는 결과가
자연히 나온다.

### 벽 타기 (`ClingController`)

붙는 지점은 **벽의 오브젝트 공간**에 저장되고 매 프레임 월드 공간으로 다시 투영된다. 그래서
움직이는 자석 벽(7번 스테이지 타이밍 퍼즐)에 붙으면 벽이 플레이어를 태우고 다닌다 — 별도
처리가 필요 없다.

`PlatformStand` 대신 `AutoRotate = false`를 쓴다. 등반 속도는 `humanoid.MoveDirection`을
읽어서 결정하는데 `PlatformStand`가 그 값을 0으로 만들기 때문이다. 위치 유지는
`AlignPosition`이 담당한다.

---

## 스테이지를 코드로 만드는 이유

지오메트리를 `.rbxm`이 아니라 Lua 데이터로 두고 런타임에 `StageBuilder`가 생성한다.

- 레이아웃 변경이 읽을 수 있는 diff로 남는다
- 12개 스테이지가 불투명한 바이너리 12개가 아니라 작은 파일 12개가 된다
- 태그와 어트리뷰트를 읽는 코드와 붙이는 코드가 같은 저장소에 있으므로 어긋날 수 없다
- 1인 개발에서 Studio와 git을 오가는 비용이 사라진다

대가는 지오메트리를 손으로 쓴다는 것이다. 이를 감당 가능하게 만드는 것이 `StageBuilder`의
기본값들과 네 가지 헬퍼(트리거 / 자석 소품 / 소켓 / 게이트)다.

스테이지끼리는 X축으로 2000 studs씩 떨어뜨려 배치하고 허브는 -2000에 둔다. 레이아웃 좌표는
전부 스테이지 원점 기준의 상대 좌표라 스테이지를 옮겨도 레이아웃을 고칠 필요가 없다.

### 스테이지 초기화

스테이지는 서버 전체가 공유하는 공간이다. 누군가 푼 퍼즐이 다음 사람에게 풀린 채로 남으면
안 되므로, **주행이 시작될 때 그 스테이지를 달리는 사람이 자기 혼자면** 퍼즐·게이트·적을
되돌린다. 완전한 인스턴싱 없이 공유 서버를 정직하게 유지하는 방법이고, 나중에 인스턴싱이
필요해지면 `StageService.ResetStage`가 그 시작점이다.
