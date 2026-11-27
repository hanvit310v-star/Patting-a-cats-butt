# Patting a cat's butt (고양이 궁디팡팡)

맥북 트랙패드 **왼쪽 옆 / 오른쪽 옆 몸체**를 톡톡 두드리면, 화면 속 고양이가 엉덩이를 돌리며 반응하는 작은 macOS 앱입니다.
1초 동안 두드리지 않으면 고양이가 뒤를 돌아봅니다.

A tiny macOS toy: tap the left or right side of your MacBook's palm rest and the cat on screen turns its butt. Stop tapping for a second and the cat looks back at you.

## 동작 방식
- 맥북에 내장된 **움직임 센서(가속도계 + 회전 센서)** 값을 1초에 약 800번 읽습니다.
- 값이 갑자기 튀면 "두드림"으로 보고, 노트북을 들거나 옮기는 움직임은 걸러냅니다.
- 앱을 켜면 **튜토리얼**에서 왼쪽·오른쪽을 각각 5번 두드려 사용자의 두드림을 학습한 뒤, 그 기준으로 좌우를 구분합니다.
- 센서가 없는 맥에서는 키보드 **← →** 키로 두드릴 수 있습니다.
- 튜토리얼이 끝난 뒤 두드릴 때마다 화면 가운데에 **PERFECT** 문구가 뜨고, 고양이가 뒤를 돌아볼 때 소리가 납니다.

## 필요 환경
- 움직임 센서가 있는 Apple Silicon 맥북 (M2 MacBook Air에서 만들고 시험함)
- macOS 14 이상
- 앱을 직접 만들려면 Xcode 명령줄 도구(`swiftc`)

## 실행 방법
**만들어진 앱 쓰기**: Releases의 zip을 받아 압축을 풀고, 앱을 **우클릭 → 열기 → 열기**로 처음 한 번 실행합니다. (Apple 인증을 받지 않은 앱이라 경고가 뜹니다)

**직접 만들기**:
```bash
./build.sh
open "build/고양이 궁디팡팡.app"
```

## 파일 구성
| 파일 | 내용 |
|---|---|
| `Sources/main.swift` | 앱 전체 코드 (센서 감지, 좌우 판별, 화면) |
| `Sources/PerfectBadge.swift` | 두드릴 때 화면 가운데에 뜨는 PERFECT 문구 |
| `Resources/` | 고양이 이미지 2장 (뒤돈 모습, 뒤돌아본 모습)과 뒤돌아볼 때 나는 소리 파일 |
| `Info.plist` | 앱 이름 등 기본 정보 |
| `build.sh` | 앱을 만드는 스크립트 |

## 알아둘 점
- 센서는 Apple이 공식 문서로 공개하지 않은 방식으로 읽습니다. macOS 업데이트나 맥 모델에 따라 동작하지 않을 수 있습니다.
- 고양이 사진은 인터넷에서 가져온 이미지로, **원 저작자를 확인하지 못했습니다.** 개인 학습·연습용으로만 사용해 주세요. 저작권자의 요청이 있으면 삭제하겠습니다.

국민대학교 AX-Startup 부트캠프 2기 실습으로 만들었습니다.
