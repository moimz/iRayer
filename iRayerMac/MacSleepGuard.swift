import IOKit.pwr_mgt

/// 영상 재생·파일 작업 중에는 화면이 꺼지거나 잠들지 않게 한다 (아이폰의 자동 잠금 끄기에 해당)
final class MacSleepGuard {
    static let shared = MacSleepGuard()

    private var assertion: IOPMAssertionID = 0
    private var active = false

    private init() {}

    func preventSleep(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "iRayer 재생 중" as CFString, &assertion)
        } else {
            IOPMAssertionRelease(assertion)
        }
    }
}
