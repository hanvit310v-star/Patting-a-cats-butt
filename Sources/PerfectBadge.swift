// 두드릴 때마다 화면 가운데에 뜨는 "PERFECT" 문구 (리듬게임 느낌)
//  1) 아래에서 빠르게 올라와서 점점 느려지고 (ease-out)
//  2) 잠깐 머문 뒤
//  3) 서서히 사라집니다 (페이드아웃)

import SwiftUI

// MARK: - 바꿔 볼 수 있는 설정값

enum PerfectConfig {
    static let fontSize: CGFloat = 54          // 글자 크기
    static let riseFrom: CGFloat = 90          // 처음 시작하는 위치(가운데보다 얼마나 아래인지, 포인트)
    static let riseDuration: Double = 0.42     // 아래에서 올라오는 시간(초). 짧을수록 빠르게 튀어 오름
    static let holdTime: Double = 0.55         // 올라오기 시작한 뒤 사라지기 시작할 때까지의 시간(초)
    static let fadeDuration: Double = 0.45     // 사라지는 데 걸리는 시간(초)
}

// MARK: - 글자 모양 (노란 그라데이션 + 진한 테두리)

struct PerfectLabel: View {
    private let outline = Color(red: 0.35, green: 0.2, blue: 0.1)
    private let offsets: [CGSize] = [
        CGSize(width: -3, height: 0), CGSize(width: 3, height: 0),
        CGSize(width: 0, height: -3), CGSize(width: 0, height: 3),
        CGSize(width: -2, height: -2), CGSize(width: 2, height: -2),
        CGSize(width: -2, height: 2), CGSize(width: 2, height: 2),
    ]

    private func text() -> some View {
        Text("PERFECT")
            .font(.system(size: PerfectConfig.fontSize, weight: .heavy, design: .rounded))
            .tracking(2)
            .fixedSize()
    }

    var body: some View {
        ZStack {
            ForEach(0..<offsets.count, id: \.self) { i in
                text().foregroundStyle(outline).offset(offsets[i])
            }
            text().foregroundStyle(outline).offset(x: 0, y: 5)          // 아래 그림자
            text().foregroundStyle(
                LinearGradient(colors: [Color(red: 1.0, green: 0.96, blue: 0.55),
                                        Color(red: 1.0, green: 0.62, blue: 0.20)],
                               startPoint: .top, endPoint: .bottom))
        }
    }
}

// MARK: - 움직임: trigger 숫자가 바뀔 때마다(=두드릴 때마다) 처음부터 다시 재생

struct PerfectBadge: View {
    let trigger: Int
    @State private var y: CGFloat = PerfectConfig.riseFrom
    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.85
    @State private var token = 0               // 연속으로 두드릴 때 이전 재생을 취소하기 위한 번호

    var body: some View {
        PerfectLabel()
            .scaleEffect(scale)
            .offset(y: y)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in play() }
    }

    private func play() {
        token += 1
        let t = token
        // 0) 시작 자리(아래, 투명)로 즉시 되돌림 — 애니메이션 없이
        var reset = Transaction(); reset.disablesAnimations = true
        withTransaction(reset) { y = PerfectConfig.riseFrom; opacity = 0; scale = 0.85 }
        // 1) 아래에서 빠르게 올라와 점점 느려짐 (ease-out: 처음엔 빠르고 끝에서 천천히)
        DispatchQueue.main.async {
            guard t == token else { return }
            withAnimation(.timingCurve(0.05, 0.9, 0.2, 1.0, duration: PerfectConfig.riseDuration)) {
                y = 0; scale = 1
            }
            withAnimation(.easeOut(duration: 0.10)) { opacity = 1 }
        }
        // 2) 잠깐 머문 뒤 서서히 사라짐 (살짝 위로 뜨면서 페이드아웃)
        DispatchQueue.main.asyncAfter(deadline: .now() + PerfectConfig.holdTime) {
            guard t == token else { return }
            withAnimation(.easeIn(duration: PerfectConfig.fadeDuration)) {
                opacity = 0; y = -20; scale = 1.04
            }
        }
    }
}
