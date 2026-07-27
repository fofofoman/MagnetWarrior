# 자석전사 (MagnetWarrior)

로블록스 3D 액션 플랫포머. 왼손 **Pull**(당기기), 오른손 **Push**(밀기) 두 개의 자기력으로
이동·전투·퍼즐을 전부 해결한다.

핵심 설계 원칙은 하나다. **판정은 전부 서버가 한다.** 클라이언트는 "어느 손을 눌렀고 대충
어디를 보고 있었는지"만 보고하고, 무엇을 맞췄는지·얼마나 밀렸는지·몇 초가 걸렸는지는 서버가
직접 계산한다. 랭킹 시스템의 신뢰도가 게임의 수명이기 때문이다.

---

## 시작하기

필요한 도구는 [Rokit](https://github.com/rojo-rbx/rokit)으로 고정되어 있다.

```bash
rokit install          # rojo, stylua, selene 설치
rojo serve             # Studio의 Rojo 플러그인에서 Connect
```

Studio에서 새 Baseplate를 열고 Rojo 플러그인으로 연결하면 된다. 지오메트리는 전부 코드로
생성되므로 `.rbxl`을 주고받을 필요가 없다. 서버가 부팅되면 허브와 제작된 스테이지가 자동으로
빌드된다.

```bash
rojo build -o build/MagnetWarrior.rbxl   # 배포용 place 파일 빌드
stylua src/                              # 포맷
selene src/                              # 린트
```

> **DataStore 없이도 실행된다.** Studio에서 API 접근을 켜지 않았거나 게시 전이라면
> `DataService`가 자동으로 메모리 전용 프로필로 폴백한다. 기록이 저장되지 않을 뿐 게임은 정상
> 동작한다.

### 조작

| 입력 | 동작 |
| --- | --- |
| 마우스 좌클릭 / L2 / 화면 좌측 버튼 | 왼손 Pull (누르고 있으면 그래플·벽 붙기) |
| 마우스 우클릭 / R2 / 화면 우측 버튼 | 오른손 Push |
| Tab / 게임패드 Select | 스테이지 & 랭킹판 |
| B / 게임패드 Y | 상점 & 외형 |

키보드에서는 같은 내용이 화면 하단 힌트 줄에도 뜬다 (주행 중에는 숨겨진다). 터치·게임패드는
ContextActionService가 라벨 붙은 버튼을 직접 그린다.

패널은 한 번에 하나만 열린다. 열려 있는 동안 자석은 잠기고 — 잡고 있던 것도 놓는다 — 커서는
풀린다. 상점 버튼을 누르는 것이 뒤에 있는 벽을 당기는 일이 되면 안 되기 때문이다.

---

## 프로젝트 구조

```
src/
├── shared/                     ReplicatedStorage.Shared — 서버·클라이언트 공용
│   ├── Types.luau              와이어를 넘나드는 모든 데이터의 타입
│   ├── Net.luau                모든 RemoteEvent/RemoteFunction의 단일 정의처
│   ├── Config/
│   │   ├── GameConfig.luau     기능 플래그, 태그, 콜리전 그룹
│   │   ├── MagnetConfig.luau   Pull/Push 물리 수치 (서버가 읽는 값)
│   │   ├── SoundConfig.luau    사운드 목록 + 볼륨/피치
│   │   ├── StageConfig.luau    12개 스테이지 로스터 + 메달 기준시간
│   │   └── MonetizationConfig.luau  판매 항목 + Pay-to-win 차단 검증
│   └── Util/                   Signal, Trove, RateLimiter, TimeFormat, SoundKit
│
├── server/                     ServerScriptService.Server
│   ├── init.server.luau        부팅 순서와 서비스 간 배선
│   ├── Magnet/
│   │   ├── MagnetService.luau      코어 메카닉 — 검증→타겟팅→힘 적용
│   │   ├── MagneticRegistry.luau   자석 대상 추적 + 서버 네트워크 소유권 확보
│   │   └── ClingController.luau    자석 벽 타기
│   ├── Run/
│   │   ├── RunSessionService.luau  서버 권위 타이머, 순서 체크포인트, 검증
│   │   ├── MovementAudit.luau      비정상 이동 탐지
│   │   ├── GhostRecorder.luau      주행 궤적 10Hz 기록
│   │   └── RespawnService.luau     리스폰 대기시간 (스킵 상품의 대상)
│   ├── Data/
│   │   ├── DataService.luau        버전 관리되는 프로필 DataStore
│   │   ├── RecordService.luau      개인 기록·메달 확정
│   │   ├── LeaderboardService.luau OrderedDataStore — 개인/친구/글로벌
│   │   ├── GhostService.luau       고스트 저장·열람 (열람권 소비)
│   │   └── MedalCalibration.luau   실제 완주 시간 분포 → 기준시간 제안
│   ├── Combat/
│   │   ├── EnemyService.luau       자석으로 잡히는 부유 드론
│   │   ├── CombatService.luau      충돌 속도 기반 데미지
│   │   └── BossService.luau        장갑 개폐 패턴, 스크랩 투척, 증원
│   ├── Stage/
│   │   ├── StageService.luau       월드 구축, 스테이지 선택, 해금 판정
│   │   ├── StageBuilder.luau       데이터 → 지오메트리
│   │   ├── PuzzleService.luau      철제 블록 조립
│   │   ├── MotionService.luau      움직이는 벽 + 극성 전환
│   │   ├── StageActivity.luau      플레이어 없는 스테이지 절전
│   │   ├── GateService.luau        적 전멸/퍼즐 완성 → 문 열림
│   │   ├── HazardService.luau      낙사·위험지대
│   │   └── Layouts/                스테이지 12개의 레이아웃 데이터
│   └── Monetization/
│       ├── MonetizationService.luau  MarketplaceService 연동, 영수증 처리
│       └── Entitlements.luau         보유 여부 질의의 단일 창구
│
└── client/                     StarterPlayer.StarterPlayerScripts.Client
    ├── MagnetController.luau   입력과 조준만 — 판정 없음
    ├── AudioController.luau    비위치성 피드백 사운드
    ├── State/RunState.luau     서버 타이머의 표시용 보간
    ├── Effects/
    │   ├── MagnetEffects.luau  빔, 트레일
    │   ├── ImpactEffects.luau  충돌 파티클, 화면 흔들림
    │   ├── VictoryPose.luau    클리어 승리 연출 4종
    │   └── GhostPlayer.luau    고스트 실루엣 재생
    └── UI/
        ├── Hud.luau            타이머, 메달 페이스, 쿨다운, 조작 힌트
        ├── UiState.luau        패널 하나만 열림 + 열린 동안 자석 잠금
        ├── MedalPopup.luau     결과 카드 (무효 사유 포함)
        ├── LeaderboardPanel.luau  스테이지 선택 + 개인/친구/글로벌
        ├── ShopPanel.luau      게임패스·아이템 구매, 외형 선택
        ├── RespawnPrompt.luau  사망 대기 + 즉시 재시도
        └── Toast.luau          서버 알림
```

```
tools/
└── estimate_medals.py          레이아웃 → 메달 기준시간 산출 (재실행 가능)
```

---

## 구현 현황

개발 순서 대비 진행 상황:

| 단계 | 내용 | 상태 |
| --- | --- | --- |
| 1 | 자석 Pull/Push 코어 메카닉 프로토타입 | **완료** — 그래플, 벽 타기, 밀어내기, 물체 조작 |
| 2 | 서버 사이드 타이머/랭킹 시스템 뼈대 | **완료** — 서버 타이머, 이동 감사, 개인기록, 친구 랭킹 |
| 3 | 전투/퍼즐 스테이지 추가 | **완료** |
| 4 | 메달 UI + 개인/친구 랭킹판 | **완료** — 페이스 표시 HUD, 결과 카드, 3탭 랭킹판 |
| 5 | 나머지 스테이지 제작 | **완료** — 본편 10개 전부 플레이 가능 |
| 6 | 보스전 2개 | **완료** — 장갑 개폐 패턴, 스크랩 되받아치기, 증원 |
| 7 | 게임패스/개발자 상품 연동 | **완료** — 자산 ID만 입력하면 동작 |
| 8 | 폴리싱 | **완료** — 사운드 배선, 충돌 이펙트, 화면 흔들림, 고스트 리플레이 |

### 스테이지

12개 전부 플레이 가능하다. 11·12번은 원래 "확장 여유분" 슬롯이었지만 클리어 후 도전
스테이지로 채웠다 — 로스터는 그냥 배열이라 13번 이후를 덧붙이는 데 아무 제약이 없으므로
확장 여지가 줄어들지는 않는다.

| ID | 이름 | 가르치는 것 |
| --- | --- | --- |
| `stage_01_pull` | 인력 시험장 | Pull 전용. 그래플로 협곡 건너기 + 블록 1개 조립 |
| `stage_02_push` | 척력 시험장 | Push 전용. 벽 반작용(수평 ~36칸) / 바닥 반작용(수직 ~29칸) |
| `stage_03_scrapyard` | 고철 처리장 | 전투 입문. 3개 아레나, 벽에 처박기 |
| `stage_04_crossfire` | 교차 사격장 | 적을 적에게 던지기. 고철을 일부러 줄여 놓았다 |
| `stage_05_gauntlet` | 자기장 회랑 | 이동+전투 동시. 좁은 통로에서 적을 낙사시키기 |
| `stage_06_assembly` | 조립 구역 | 철제 블록 다리 + 계단 조립 |
| `stage_07_cadence` | 박자 실험실 | 극성이 바뀌는 벽, 움직이는 벽 타기 |
| `stage_08_foundry` | 주조 공장 | 조립과 타이밍 교대. 리프트를 타고 블록 회수 |
| `stage_09_miniboss` | 폐기물 수집기 | 장갑이 열린 순간에만 통하는 자석 |
| `stage_10_finalboss` | 대자석로 | 이동·퍼즐·전투 전부 + 증원 + 움직이는 엄폐물 |
| `stage_11_extra` | 무중력 격납고 | 바닥 없음. 정지→극성→이동 벽 순서로 재복습 |
| `stage_12_extra` | 폐기 라인 | 전 구간 이동식. 페리 체인 + 시간 압박 조립 |

### 스테이지 추가하는 법

1. `src/server/Stage/Layouts/StageNN.luau`에 레이아웃 데이터 작성
   (`StageBuilder.Layout` 타입 참고 — parts / magnetic / kinetics / blocks /
   sockets / gates / enemies / boss / checkpoints)
2. `StageConfig`에서 해당 스테이지의 `hasLayout = true`로 변경
3. `StageService`의 `layouts` 테이블에 `require` 추가

체크포인트 개수가 `StageConfig`와 레이아웃에서 다르면 빌드 시점에 assert로 잡힌다.

---

## 더 읽을 것

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — 시스템 간 관계, 부팅 순서, 데이터 흐름
- [`docs/ANTI_CHEAT.md`](docs/ANTI_CHEAT.md) — 기록이 신뢰할 만한 이유, 검증 계층 전체
- [`docs/MONETIZATION.md`](docs/MONETIZATION.md) — 판매 정책, 자산 ID 연결 방법, 확장 지점

## 밸런스

**메달 기준시간은 손으로 찍은 값이 아니라 생성된 값이다.**
`tools/estimate_medals.py`가 레이아웃에서 실제 경로를 재고, 플레이어를 멈추게 하는 모든 것(적,
소켓, 게이트, 극성 대기, 보스 장갑 사이클)의 비용을 더해서 계산한다. 튜닝을 바꾼 뒤에는 추측
대신 다시 돌리면 된다.

```bash
python3 tools/estimate_medals.py            # 제안 표만 출력
python3 tools/estimate_medals.py --apply    # StageConfig에 반영
```

가정은 의도적으로 비관적이다 — 아무도 못 따는 메달은 죽은 목표지만, 조금 후한 메달은 그래도
작동하기 때문이다.

**실제 플레이 데이터가 쌓이면 그쪽이 더 정확하다.** `MedalCalibration`이 검증을 통과한 완주
시간을 스테이지별 히스토그램으로 모은다. 서버 콘솔이나 Studio 커맨드바에서:

```lua
require(game.ServerScriptService.Server.Data.MedalCalibration).Report()
require(game.ServerScriptService.Server.Data.MedalCalibration).ProposeConfig()
```

p20/p50/p80과 현재 기준시간을 나란히 보여주고, 붙여넣을 수 있는 `StageConfig` 줄을 뽑아준다.
스테이지당 100회 정도 쌓이기 전에는 참고만 하면 된다.

**스테이지 슬립 상태 확인.** 12개 스테이지가 한 월드에 동시에 존재하고, 아무도 근처에 없는
스테이지는 시뮬레이션을 멈춘다. 벽이 안 움직이거나 적이 안 오는 것 같으면 먼저 이걸 본다:

```lua
require(game.ServerScriptService.Server.Stage.StageActivity).AwakeStages()
```

깨어 있는 스테이지 목록을 돌려준다. 비어 있으면 아무도 어느 스테이지에도 없다는 뜻이다.

### 알아둘 것

- **하울러는 벽에 처박아 죽일 수 없다.** 질량 108이라 슬램으로는 17 데미지(150 HP)밖에 안 나온다.
  의도된 것이다 — 하울러는 *처박는 대상*이 아니라 *처박는 도구*이고, 상자나 다른 적을 던져야
  잡힌다. 4번 스테이지가 가르치려는 것이 정확히 이것이다.
- **보스 데미지의 70% 정도는 스크랩 되받아치기에서 나온다.** 코어 뽑기(Pull)는 보조다. 이 비율이
  뒤집히면 "가까이 붙어서 Pull만 연타"가 최적해가 되므로, `YANK_COOLDOWN`을 만질 때는 확인이
  필요하다.

## 남은 것

- **사운드 에셋.** 배선은 끝났다 — 32개 사운드가 전부 호출 지점에 연결되어 있고
  `SoundConfig`의 `assetId`가 `0`인 동안에는 조용히 no-op이다. 크리에이터 대시보드에서 만든
  ID를 그 표에 넣으면 다른 파일을 건드리지 않고 소리가 난다. (게임패스 자산 ID와 같은 방식)
  오디오 파일 자체는 업로드가 필요해서 코드로 해결할 수 있는 부분이 아니다.
- **시즌 패스와 리워드 광고는 기획서대로 미구현이다.** "후순위, 지금 구현 안 함 — 연동 구조만
  확장 가능하게"라고 지정하신 대로 자리만 잡혀 있고, `Validate()`가 그 자리에도 Pay-to-win
  검사를 건다. 구현이 필요하시면 말씀해 주세요.

## 알려진 제약

- **스테이지는 서버 전체가 공유한다.** 같은 스테이지를 아무도 달리고 있지 않을 때 퍼즐·적·문이
  초기화된다. 완전한 인스턴싱이 필요해지면 `StageService.ResetStage`가 시작점이다.
