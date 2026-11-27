// 고양이 궁디팡팡
// 맥북 트랙패드 왼쪽/오른쪽 몸체를 탁! 치면 고양이 엉덩이가 그쪽을 향하고,
// 안 치면 고양이가 뒤돌아봅니다.

import SwiftUI
import AppKit
import IOKit
import IOKit.hid

// MARK: - 바꿔 볼 수 있는 설정값

enum Config {
    static let turnDelay: Double = 1.0          // 마지막으로 친 뒤 뒤돌아보기까지 기다리는 시간(초)
    static let defaultJerk: Double = 0.008      // 기본 감도(처음 두드릴 때만 사용, 튜토리얼 후 자동 조정). 작을수록 민감
    static let quietJerk: Double = 0.004        // 가만히 둘 때 센서 잡음은 약 0.0017. 두드리기 직전에 이보다 크게 움직이고 있었다면 "들고 있는 중"으로 보고 무시
    static let rampSamples = 20                 // 두드림 자체가 커지는 구간(약 25ms)은 "직전 움직임"에서 제외
    static let quietSamples = 64                // 직전 움직임을 살펴볼 센서 값 개수(약 80ms)
    static let directionSamples = 16            // 방향 판단에 쓰는 센서 값 개수(약 20ms)
    static let minPeak: Double = 0.02           // 이보다 약한 흔들림은 무시(g)
    static let postLimit: Double = 0.05         // 두드린 뒤에도 이만큼 기울어져 있으면 "들어 올림"으로 보고 무시(g)
    static let tappingWindow: Double = 0.8      // 방금(이 시간 안에) 두드렸다면 "연속 두드리는 중"으로 보고 움직임·기울기 검사를 건너뜀
    static let minConfidence: Double = 0.25     // 좌우 확신도가 이보다 낮으면(옆면이 아닌 곳을 치거나 타자 진동 등) 반응하지 않음
    static let refractory: Double = 0.18        // 한 번 감지한 뒤 다음 감지까지 쉬는 시간(초)
    static let catWidth: CGFloat = 300          // 화면에 보이는 고양이 너비(포인트)
    static let captureSamples = 64              // 친 뒤 살펴볼 센서 값 개수(약 80ms)
    static let calibrationTaps = 5              // 좌우 맞추기 때 한쪽당 치는 횟수
    static let alwaysOnTop = true               // 창을 항상 맨 위에 둘지
}

enum Side { case left, right }

// MARK: - 움직임 센서(가속도계)로 "탁!" 감지

final class HitDetector {
    /// "탁!"으로 인정하는 최소 급변 정도. 튜토리얼에서 사용자의 두드림에 맞춰 자동 조정됩니다.
    var jerkTrigger: Double = Config.defaultJerk
    /// 친 순간의 좌우 단서 2개(가속도 x축의 첫 밀림, 회전센서 y축의 첫 회전)와 급변 세기를 알려줍니다.
    var onHit: ((SIMD2<Double>, Double) -> Void)?
    private(set) var reportCount = 0

    private var prev = SIMD3<Double>(repeating: 0)
    private var hasPrev = false
    private var baseline = SIMD3<Double>(repeating: 0)     // 평소 상태(중력 방향)
    private var recent = [Double](repeating: 0, count: Config.quietSamples)  // 직전 움직임 기록
    private var recentIdx = 0
    private var lastHit: CFTimeInterval = 0
    private var capturing = 0
    private var window: [SIMD3<Double>] = []
    private var baseAtHit = SIMD3<Double>(repeating: 0)
    private var peakJerk = 0.0
    private var hitTime: CFTimeInterval = 0
    private var lastAccepted: CFTimeInterval = 0       // 마지막으로 "두드림"으로 인정한 시각
    private var lastIgnoreLog: CFTimeInterval = 0
    private var manager: IOHIDManager?
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var usageByBuffer: [Int: Int] = [:]
    // 최근 센서 값 기록(시각, 값): 두드리기 직전·직후 흔들림을 시간으로 잘라 보기 위해 보관
    private var accHist: [(t: Double, v: SIMD3<Double>)] = []
    private var gyroHist: [(t: Double, v: SIMD3<Double>)] = []

    /// 확인용 기록 파일 (왜 반응했는지/무시했는지)
    static func log(_ text: String) {
        let line = String(format: "%.2f ", CACurrentMediaTime()) + text + "\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/catpang.log") {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(toFile: "/tmp/catpang.log", atomically: true, encoding: .utf8)
        }
    }

    /// 센서를 켜고 값을 받기 시작합니다. 센서가 없으면 false.
    func start() -> Bool {
        // 1) 센서 드라이버 깨우기
        var it: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS {
            var s = IOIteratorNext(it)
            while s != 0 {
                IORegistryEntrySetCFProperty(s, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
                IORegistryEntrySetCFProperty(s, "SensorPropertyPowerState" as CFString, 1 as CFNumber)
                IORegistryEntrySetCFProperty(s, "ReportInterval" as CFString, 1000 as CFNumber)
                IOObjectRelease(s)
                s = IOIteratorNext(it)
            }
            IOObjectRelease(it)
        }
        // 2) 가속도계(번호 3)와 회전 센서로 보이는 센서(번호 9) 열기 (애플 전용 번호 0xFF00)
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(m, ["PrimaryUsagePage": 0xFF00] as CFDictionary)
        guard IOHIDManagerOpen(m, 0) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>, !devices.isEmpty else { return false }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var foundAccel = false
        for d in devices {
            let usage = (IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? -1
            guard usage == 3 || usage == 9 else { continue }
            if usage == 3 { foundAccel = true }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            buffers.append(buf)
            usageByBuffer[Int(bitPattern: buf)] = usage     // 어느 센서의 값인지 구분하기 위한 표시
            IOHIDDeviceRegisterInputReportCallback(d, buf, 64, { ctx, _, _, _, _, report, length in
                guard let ctx, length >= 18 else { return }
                let me = Unmanaged<HitDetector>.fromOpaque(ctx).takeUnretainedValue()
                let p = UnsafeRawPointer(report)
                func axis(_ offset: Int) -> Double {
                    Double(p.loadUnaligned(fromByteOffset: offset, as: Int32.self)) / 65536.0
                }
                let v = SIMD3(axis(6), axis(10), axis(14))
                if me.usageByBuffer[Int(bitPattern: report)] == 9 {
                    me.gyroHist.append((CACurrentMediaTime(), v))
                    if me.gyroHist.count > 1200 { me.gyroHist.removeFirst(600) }
                } else {
                    me.process(v)
                }
            }, ctx)
        }
        if !foundAccel { return false }
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        manager = m
        return true
    }

    private func norm(_ v: SIMD3<Double>) -> Double { (v * v).sum().squareRoot() }

    private func process(_ a: SIMD3<Double>) {
        reportCount += 1
        accHist.append((CACurrentMediaTime(), a))
        if accHist.count > 1200 { accHist.removeFirst(600) }
        if !hasPrev { prev = a; baseline = a; hasPrev = true; return }
        let jerk = norm(a - prev)          // 직전 값과의 차이 = 얼마나 "갑자기" 변했나
        prev = a

        // 친 직후 약 80ms 동안 흔들림을 모음 (방향 판단 + 그 뒤 가만히 있는지 확인용)
        if capturing > 0 {
            window.append(a - baseAtHit)
            peakJerk = max(peakJerk, jerk)
            capturing -= 1
            if capturing == 0 { finishWindow() }
            return
        }

        // 직전 움직임: 두드림이 커지는 구간(가장 최근 약 25ms)은 빼고, 그보다 앞선 약 55ms를 봄
        var before = 0.0
        for k in 0..<(recent.count - Config.rampSamples) {
            before = max(before, recent[(recentIdx + k) % recent.count])
        }
        recent[recentIdx] = jerk
        recentIdx = (recentIdx + 1) % recent.count

        let now = CACurrentMediaTime()
        if jerk > jerkTrigger && now - lastHit > Config.refractory {
            // 들고 있거나 옮기는 중이라 이미 계속 움직이고 있었다면 "두드림"이 아님
            // (방금 두드렸다면 연속으로 두드리는 중이라, 앞 두드림의 잔 떨림은 봐줌)
            let tapping = now - lastAccepted < Config.tappingWindow
            if before > Config.quietJerk && !tapping {
                if now - lastIgnoreLog > 0.5 {
                    lastIgnoreLog = now
                    HitDetector.log(String(format: "무시(움직이는 중) jerk=%.4f before=%.4f", jerk, before))
                }
                return
            }
            lastHit = now
            hitTime = now
            baseAtHit = baseline
            window = [a - baseAtHit]
            peakJerk = jerk
            capturing = Config.captureSamples
            return
        }
        baseline = baseline * 0.98 + a * 0.02   // 평소 상태 천천히 갱신
    }

    private func finishWindow() {
        let head = Array(window.prefix(Config.directionSamples))
        let mags = head.map { norm($0) }
        guard let peak = mags.max(), peak > 0,
              let i = mags.firstIndex(where: { $0 >= peak * 0.6 }) else { return }
        // 두드린 뒤 자세(기울기)가 그대로여야 함. 들어 올리거나 기울였다면 계속 달라져 있음
        let tail = window.suffix(16)
        let tailMean = tail.reduce(SIMD3<Double>(repeating: 0), +) / Double(tail.count)
        let after = norm(tailMean)
        // 연속으로 두드리는 중에는 앞 두드림의 떨림 때문에 "기울어짐" 값이 커지므로 이 검사를 건너뜀
        let continuing = hitTime - lastAccepted < Config.tappingWindow
        let ok = peak >= Config.minPeak && (continuing || after <= max(Config.postLimit, peak * 0.3))
        HitDetector.log(String(format: "%@ peak=%.3f jerk=%.4f after=%.3f 기준=%.4f",
                               ok ? "반응" : (peak < Config.minPeak ? "무시(너무 약함)" : "무시(들거나 기울임)"),
                               peak, peakJerk, after, jerkTrigger))
        if ok { lastAccepted = hitTime; onHit?(leftRightClues(), peakJerk) }
    }

    /// 왼쪽/오른쪽을 가르는 단서 2개 (두드림 데이터 64번을 분석해서 찾은 것):
    ///  ① 가속도 x축이 처음 크게 밀린 값  ② 회전센서 y축이 처음 크게 돈 값
    /// 모두 "두드리기 직전(약 35~70ms 전)" 상태를 기준으로 한 변화량입니다.
    private func leftRightClues() -> SIMD2<Double> {
        func clue(_ hist: [(t: Double, v: SIMD3<Double>)], axis: Int) -> Double {
            let pre = hist.filter { $0.t >= hitTime - 0.07 && $0.t <= hitTime - 0.035 }
            guard !pre.isEmpty else { return 0 }
            let base = pre.map { $0.v[axis] }.reduce(0, +) / Double(pre.count)
            let seg = hist.filter { $0.t >= hitTime - 0.01 && $0.t <= hitTime + 0.03 }.map { $0.v[axis] - base }
            guard let peak = seg.max(by: { abs($0) < abs($1) }) else { return 0 }
            return seg.first(where: { abs($0) >= 0.5 * abs(peak) }) ?? 0
        }
        return SIMD2(clue(accHist, axis: 0), clue(gyroHist, axis: 1))
    }
}

// MARK: - 고양이 상태

final class CatModel: ObservableObject {
    enum Calibration: Equatable { case off, left(Int), right(Int) }
    /// 화면 단계: 좌우 맞추기 튜토리얼 → "이해했어요!" 안내문 → 놀기
    enum Phase { case tutorial, guide, play }

    @Published var side: Side = .right
    @Published var showTurn = false
    @Published var hitCount = 0
    @Published var turnCount = 0
    @Published var status = ""
    @Published var calibration: Calibration = .off
    @Published var sensorOK = false
    @Published var phase: Phase = .tutorial
    @Published var tutorialDone = false
    @Published var tutorialNote = ""

    let detector = HitDetector()
    private var turnTimer: Timer?
    private var leftSamples: [SIMD2<Double>] = []
    private var rightSamples: [SIMD2<Double>] = []
    private var tutorialJerks: [Double] = []
    /// 튜토리얼에서 배운 좌우 기준: 왼쪽 평균, 오른쪽 평균, 단서별 흩어진 정도
    private var model: (mL: SIMD2<Double>, mR: SIMD2<Double>, sd: SIMD2<Double>)?

    /// 예전에 맞춰 둔 좌우 정보가 있는지 (있으면 튜토리얼 건너뛰기 가능)
    var hasSavedCalibration: Bool { model != nil }

    init() {
        let savedJerk = UserDefaults.standard.double(forKey: "jerkTriggerV3")
        if savedJerk > 0 { detector.jerkTrigger = savedJerk }
        if let m = UserDefaults.standard.array(forKey: "clueModelV4") as? [Double], m.count == 6 {
            model = (SIMD2(m[0], m[1]), SIMD2(m[2], m[3]), SIMD2(m[4], m[5]))
        }
        detector.onHit = { [weak self] clues, jerk in self?.sensorHit(clues, jerk) }
        sensorOK = detector.start()
        status = sensorOK ? "열심히 궁뎅이를 팡팡해줍시다."
                          : "움직임 센서를 찾지 못했어요. ← → 키로 쳐 보세요."
        if sensorOK {
            startCalibration()          // 켜자마자 튜토리얼부터
        } else {
            phase = .guide              // 센서가 없으면 튜토리얼 없이 안내문만
        }
        // 센서 신호가 들어오는지 확인용 기록
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            print("sensor ok: \(self?.sensorOK ?? false), reports in 2s: \(self?.detector.reportCount ?? 0)")
            fflush(stdout)
        }
    }

    // "이해했어요!" → 놀기 시작
    func closeGuide() {
        phase = .play
    }

    // 튜토리얼 끝(건너뛰기 포함) → "이해했어요!" 안내문으로
    func goToGuide() {
        calibration = .off
        phase = .guide
    }

    // 센서가 "탁!"을 감지했을 때
    private func sensorHit(_ clues: SIMD2<Double>, _ jerk: Double) {
        if phase == .guide { return }
        switch calibration {
        case .left(let n):
            leftSamples.append(clues); tutorialJerks.append(jerk)
            hit(.left)
            calibration = n + 1 >= Config.calibrationTaps ? .right(0) : .left(n + 1)
        case .right(let n):
            rightSamples.append(clues); tutorialJerks.append(jerk)
            hit(.right)
            if n + 1 >= Config.calibrationTaps { finishCalibration() } else { calibration = .right(n + 1) }
        case .off:
            if let side = classify(clues) { hit(side) }
        }
    }

    /// 맞추기 때 기억한 왼쪽/오른쪽 흔들림 방향 중 어느 쪽에 더 가까운지로 판단
    private func classify(_ clues: SIMD2<Double>) -> Side? {
        guard let m = model else { return .left }
        // 단서마다 "왼쪽 평균과 오른쪽 평균의 중간"을 기준으로, 어느 쪽에 더 가까운지 점수를 매깁니다.
        // (흩어짐이 작은 단서일수록 더 믿습니다)
        let w = (m.mL - m.mR) / (m.sd * m.sd)
        let mid = (m.mL + m.mR) / 2
        let score = ((clues - mid) * w).sum()
        // 확신도: 튜토리얼 때의 "평균적인 왼쪽 두드림"을 +1, "평균적인 오른쪽 두드림"을 -1로 본 값.
        // 0 근처면 옆면을 친 게 아니라는 뜻(트랙패드 가운데, 타자 진동 등)
        let typical = max(((m.mL - mid) * w).sum(), 1e-6)
        let confidence = score / typical
        HitDetector.log(String(format: "  단서 x=%+.3f gy=%+.2f → 확신도 %+.2f → %@", clues.x, clues.y, confidence,
                               abs(confidence) < Config.minConfidence ? "무시(옆면이 아님)" : (score > 0 ? "왼쪽" : "오른쪽")))
        if abs(confidence) < Config.minConfidence { return nil }
        return score > 0 ? .left : .right
    }

    private func startCalibration() {
        leftSamples = []; rightSamples = []; tutorialJerks = []
        tutorialDone = false
        calibration = .left(0)
    }

    private func finishCalibration() {
        func mean(_ a: [SIMD2<Double>]) -> SIMD2<Double> { a.reduce(.zero, +) / Double(a.count) }
        func fit(_ ls: [SIMD2<Double>], _ rs: [SIMD2<Double>]) -> (mL: SIMD2<Double>, mR: SIMD2<Double>, sd: SIMD2<Double>) {
            let all = ls + rs
            let mu = mean(all)
            let variance = all.map { ($0 - mu) * ($0 - mu) }.reduce(.zero, +) / Double(all.count)
            return (mean(ls), mean(rs), SIMD2(max(variance.x.squareRoot(), 1e-6), max(variance.y.squareRoot(), 1e-6)))
        }
        func isLeft(_ m: (mL: SIMD2<Double>, mR: SIMD2<Double>, sd: SIMD2<Double>), _ c: SIMD2<Double>) -> Bool {
            let w = (m.mL - m.mR) / (m.sd * m.sd)
            return ((c - (m.mL + m.mR) / 2) * w).sum() > 0
        }
        // 튜토리얼 중 안내와 다른 쪽을 두드렸거나 이상하게 두드린 것은 빼고 다시 계산
        var ls = leftSamples, rs = rightSamples
        var m = fit(ls, rs)
        let keptL = ls.filter { isLeft(m, $0) }, keptR = rs.filter { !isLeft(m, $0) }
        if keptL.count < ls.count || keptR.count < rs.count {
            HitDetector.log("튜토리얼: 안 맞는 두드림 \(ls.count - keptL.count + rs.count - keptR.count)번 제외")
            ls = keptL; rs = keptR
            if ls.count >= 3 && rs.count >= 3 { m = fit(ls, rs) }
        }
        if ls.count < 3 || rs.count < 3 {
            // 너무 섞여서 기준을 만들 수 없음 → 처음부터 다시
            HitDetector.log("튜토리얼: 두드림이 너무 섞여 처음부터 다시")
            tutorialNote = "두드림이 섞였어요. 왼쪽, 오른쪽을 구분해서 다시 해 볼게요!"
            startCalibration()
            return
        }
        tutorialNote = ""
        let l = m.mL, r = m.mR, sd = m.sd
        model = m
        UserDefaults.standard.set([l.x, l.y, r.x, r.y, sd.x, sd.y], forKey: "clueModelV4")
        HitDetector.log(String(format: "튜토리얼 완료: 왼쪽 평균(x=%+.3f, gy=%+.2f) 오른쪽 평균(x=%+.3f, gy=%+.2f)", l.x, l.y, r.x, r.y))
        // 사용자의 두드림 세기에 맞춰 감도 자동 조정: 가장 약했던 두드림의 절반 정도부터 반응
        if let weakest = tutorialJerks.min() {
            let j = min(max(weakest * 0.5, 0.008), 0.05)
            detector.jerkTrigger = j
            UserDefaults.standard.set(j, forKey: "jerkTriggerV3")
            HitDetector.log(String(format: "튜토리얼 완료: 가장 약한 두드림 jerk=%.4f → 새 기준=%.4f", weakest, j))
        }
        calibration = .off
        tutorialDone = true
        // "준비 완료!"를 잠깐 보여 준 뒤 안내문으로
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            if self?.phase == .tutorial { self?.goToGuide() }
        }
    }

    /// 팡! (센서나 ← → 키에서 호출)
    func hit(_ s: Side) {
        if phase == .guide { return }
        turnTimer?.invalidate()
        side = s
        showTurn = false
        hitCount += 1
        turnTimer = Timer.scheduledTimer(withTimeInterval: Config.turnDelay, repeats: false) { [weak self] _ in
            self?.turnAround()
        }
    }

    private func turnAround() {
        showTurn = true
        turnCount += 1
    }
}

// MARK: - 화면

struct Squish { var sx: CGFloat = 1; var sy: CGFloat = 1 }

struct CatView: View {
    @ObservedObject var model: CatModel
    let back = NSImage(named: "cat_back") ?? NSImage()
    let turn = NSImage(named: "cat_turn") ?? NSImage()

    var body: some View {
        VStack(spacing: 32) {   // 고양이와 아래 문구 사이 간격
            ZStack(alignment: .bottom) {
                // 치거나 뒤돌아볼 때마다 같은 "뿅!" 효과(가로로 늘었다 통통 튀며 복귀)
                catImage(model.showTurn ? turn : back)
                    .keyframeAnimator(initialValue: Squish(), trigger: model.hitCount + model.turnCount) { content, v in
                        content.scaleEffect(x: v.sx, y: v.sy, anchor: .bottom)
                    } keyframes: { _ in
                        KeyframeTrack(\.sx) {
                            CubicKeyframe(1.07, duration: 0.05)
                            SpringKeyframe(1.0, duration: 0.4, spring: .bouncy(extraBounce: 0.3))
                        }
                        KeyframeTrack(\.sy) {
                            CubicKeyframe(0.92, duration: 0.05)
                            SpringKeyframe(1.0, duration: 0.4, spring: .bouncy(extraBounce: 0.3))
                        }
                    }
            }
            .frame(width: Config.catWidth + 40, height: 400, alignment: .bottom)

            Text(model.status)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .opacity(model.phase == .play ? 1 : 0)
        }
        .padding(.top, 16).padding(.horizontal, 16).padding(.bottom, 36)   // 창 아래쪽 여백
        .frame(width: Config.catWidth + 80)
        .overlay {
            switch model.phase {
            case .guide: guide.transition(.opacity)
            case .tutorial: tutorial.transition(.move(edge: .top).combined(with: .opacity))
            case .play: EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.phase)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.calibration)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.tutorialDone)
    }

    // 1단계: 앱을 켰을 때 가운데에 뜨는 안내문
    var guide: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.35))
            VStack(spacing: 18) {
                Text("🐾").font(.system(size: 40))
                Text("트랙패드 양옆을 번갈아 두드리며\n엉덩이를 토닥여 주세요!")
                    .font(.system(size: 17, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.closeGuide() } label: {
                    Text("이해했어요!")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 120)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 18).fill(.background))
            .shadow(radius: 12)
            .padding(24)
        }
    }

    // 2단계: 좌우 맞추기 튜토리얼 (고양이가 보이도록 위쪽에 작게)
    var tutorial: some View {
        VStack(spacing: 12) {
            if !model.tutorialNote.isEmpty {
                Text(model.tutorialNote).font(.caption).foregroundStyle(.orange)
            }
            Text("튜토리얼 · 좌우 맞추기")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            switch model.calibration {
            case .left(let n):
                tutorialStep(emoji: "👈", text: "트랙패드 **왼쪽** 옆을\n\(Config.calibrationTaps)번 두드려 주세요", done: n)
            case .right(let n):
                tutorialStep(emoji: "👉", text: "좋아요! 이번엔 **오른쪽** 옆을\n\(Config.calibrationTaps)번 두드려 주세요", done: n)
            case .off:
                Text("🎉").font(.system(size: 30))
                Text("준비 완료!")
                    .font(.system(size: 15, weight: .bold))
                    .multilineTextAlignment(.center)
            }

            if !model.tutorialDone && model.hasSavedCalibration {
                Button("지난번 설정으로 건너뛰기") { model.goToGuide() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(.background))
        .shadow(radius: 10)
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    func tutorialStep(emoji: String, text: LocalizedStringKey, done: Int) -> some View {
        VStack(spacing: 10) {
            Text(emoji).font(.system(size: 30))
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {   // 몇 번 두드렸는지 동그라미로 표시
                ForEach(0..<Config.calibrationTaps, id: \.self) { i in
                    Circle()
                        .fill(i < done ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 12, height: 12)
                        .scaleEffect(i < done ? 1.15 : 1)
                }
            }
        }
    }

    func catImage(_ img: NSImage) -> some View {
        Image(nsImage: img)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: Config.catWidth)
            // 원본 사진은 엉덩이가 오른쪽을 향함.
            // 왼쪽을 두드리면 엉덩이가 오른쪽(원본 그대로), 오른쪽을 두드리면 왼쪽(좌우반전)
            .scaleEffect(x: model.side == .right ? -1 : 1, y: 1)
    }
}

// MARK: - 앱 시작

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = CatModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "고양이 궁디팡팡"
        window.contentView = NSHostingView(rootView: CatView(model: model))
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        if Config.alwaysOnTop { window.level = .floating }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 센서가 없을 때나 시험용: ← → 키로도 칠 수 있음
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            switch e.keyCode {
            case 123: self?.model.hit(.left); return nil
            case 124: self?.model.hit(.right); return nil
            default: return e
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
