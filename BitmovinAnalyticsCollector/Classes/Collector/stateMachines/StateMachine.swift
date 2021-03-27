import AVFoundation
import Foundation

public class StateMachine {
    private static var kVideoStartFailedTimeoutSeconds: TimeInterval = 60
    private static var kvideoStartFailedTimerId: String = "com.bitmovin.analytics.core.statemachine.startupFailedTimer"
    
    private(set) var state: PlayerState
    private var config: BitmovinAnalyticsConfig
    private(set) var impressionId: String
    weak var delegate: StateMachineDelegate?
    
    //tracked player times
    private(set) var enterTimestamp: Int64?
    var potentialSeekStart: Int64 = 0
    var potentialSeekVideoTimeStart: CMTime?
    var startupTime: Int64 = 0
    private(set) var videoTimeStart: CMTime?
    private(set) var videoTimeEnd: CMTime?
    
    // heartbeat
    weak private var heartbeatTimer: Timer?
    let rebufferHeartbeatQueue = DispatchQueue.init(label: "com.bitmovin.analytics.core.statemachine.heartBeatQueue")
    private var rebufferHeartbeatTimer: DispatchWorkItem?
    private var currentRebufferIntervalIndex: Int = 0
    private let rebufferHeartbeatInterval: [Int64] = [3000, 5000, 10000, 59700]
    
    //play attempt
    var didAttemptPlayingVideo: Bool = false
    private(set) var didStartPlayingVideo: Bool = false
    private var videoStartFailedWorkItem: DispatchWorkItem?
    private(set) var videoStartFailed: Bool = false
    private(set) var videoStartFailedReason: String?
    
    // features objects
    public var qualityChangeCounter: QualityChangeCounter
    public var rebufferingTimeoutHandler: RebufferingTimeoutHandler
    
    // error tracking
    private var errorData: ErrorData? = nil

    init(config: BitmovinAnalyticsConfig) {
        self.config = config
        state = .ready
        impressionId = NSUUID().uuidString
        qualityChangeCounter = QualityChangeCounter()
//        self.rebufferingTimeoutHandler = RebufferingTimeoutHandler()
        print("Generated Bitmovin Analytics impression ID: " + impressionId.lowercased())
        
        // needs to happen after init of properties
//        self.rebufferingTimeoutHandler.initialise(stateMachine: self)
        print("Initialized Rebuffering Timeout Handler: ")

    }

    deinit {
        disableHeartbeat()
        disableRebufferHeartbeat()
    }

    public func reset() {
        impressionId = NSUUID().uuidString
        didAttemptPlayingVideo = false
        didStartPlayingVideo = false
        startupTime = 0
        disableHeartbeat()
        disableRebufferHeartbeat()
        state = .ready
        resetVideoStartFailed()
        qualityChangeCounter.resetInterval()
//        rebufferingTimeoutHandler.resetInterval()
        print("Generated Bitmovin Analytics impression ID: " +  impressionId.lowercased())
    }

    public func transitionState(destinationState: PlayerState, time: CMTime?) {
        let performTransition = checkUnallowedTransitions(destinationState: destinationState)

        if performTransition {
            print("[StateMachine] Transitioning from state \(state) to \(destinationState)")
            let timestamp = Date().timeIntervalSince1970Millis
            let previousState = state
            videoTimeEnd = time
            state.onExit(stateMachine: self, timestamp: timestamp, destinationState: destinationState)
            state = destinationState
            enterTimestamp = timestamp
            videoTimeStart = videoTimeEnd
            state.onEntry(stateMachine: self, timestamp: timestamp, previousState: previousState)
        }
    }
    
    public func play(time: CMTime?) {
        if(didStartPlayingVideo) {
            return
        }
        transitionState(destinationState: .startup, time: time)
    }
    
    public func pause(time: CMTime?) {
        let destinationState = didStartPlayingVideo ? PlayerState.paused : PlayerState.ready
        transitionState(destinationState: destinationState, time: time)
    }
    
    public func playing(time: CMTime?) {
        transitionState(destinationState: .playing, time: time)
    }
    
    public func videoQualityChange(time: CMTime?) {
        if !qualityChangeCounter.isQualityChangeEnabled() {
            return
        }
        transitionState(destinationState: .qualitychange, time: time)
    }
    
    public func audioQualityChange(time: CMTime?) {
        if !qualityChangeCounter.isQualityChangeEnabled() {
            return
        }
        transitionState(destinationState: .audiochange, time: time)
    }
    
    public func error(withError error: ErrorData, time: CMTime?) {
        self.errorData = error
        transitionState(destinationState: .error, time: time)
    }
    
    public func rebufferTimeoutReached(time: CMTime?) {
        self.errorData = ErrorData.ANALYTICS_BUFFERING_TIMEOUT_REACHED
        transitionState(destinationState: .error, time: time)
        self.delegate?.stateMachineStopsCollecting()
    }
    
    public func setDidStartPlayingVideo() {
        didStartPlayingVideo = true
    }
    
    public func startVideoStartFailedTimer() {
        // The second test makes sure to not start the timer during an ad or if the player is paused on resuming from background
        if(didStartPlayingVideo || state != .startup) {
            return
        }
        clearVideoStartFailedTimer()
        
        videoStartFailedWorkItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.errorData = ErrorData.ANALYTICS_VIDEOSTART_TIMEOUT_REACHED
            self.onPlayAttemptFailed(withReason: VideoStartFailedReason.timeout)
        }
        DispatchQueue.init(label: StateMachine.kvideoStartFailedTimerId).asyncAfter(deadline: .now() + StateMachine.kVideoStartFailedTimeoutSeconds, execute: videoStartFailedWorkItem!)
    }
    
    public func clearVideoStartFailedTimer() {
        if (videoStartFailedWorkItem == nil) {
            return
        }
        videoStartFailedWorkItem!.cancel()
        videoStartFailedWorkItem = nil
    }
    
    public func setVideoStartFailed(withReason reason: String) {
        clearVideoStartFailedTimer()
        videoStartFailed = true
        videoStartFailedReason = reason
    }
    
    public func resetVideoStartFailed() {
        videoStartFailed = false
        videoStartFailedReason = nil
    }
    
    public func onPlayAttemptFailed(withReason reason: String = VideoStartFailedReason.unknown) {
        setVideoStartFailed(withReason: reason)
        transitionState(destinationState: .playAttemptFailed, time: nil)
        self.delegate?.stateMachineStopsCollecting()
    }
    
    public func onPlayAttemptFailed(withError error: ErrorData) {
        setVideoStartFailed(withReason: VideoStartFailedReason.playerError)
        self.errorData = error
        transitionState(destinationState: .playAttemptFailed, time: nil)
        self.delegate?.stateMachineStopsCollecting()
    }
    
    private func checkUnallowedTransitions(destinationState: PlayerState) -> Bool{
        if state == destinationState {
            return false
        } else if state == .buffering && destinationState == .qualitychange {
            return false
        } else if state == .seeking && destinationState == .qualitychange {
            return false
        } else if state == .seeking && destinationState == .buffering {
            return false
        } else if state == .ready && (destinationState != .error && destinationState != .playAttemptFailed && destinationState != .startup && destinationState != .ad) {
            return false
        } else if state == .startup && (destinationState != .error && destinationState != .playAttemptFailed && destinationState != .ready && destinationState != .playing && destinationState != .ad) {
            return false
        } else if state == .ad && (destinationState != .error && destinationState != .adFinished) {
            return false
        } else if state == .playAttemptFailed {
            return false
        }
        
        return true
    }

    public func confirmSeek() {
        enterTimestamp = potentialSeekStart
        videoTimeStart = potentialSeekVideoTimeStart
        potentialSeekStart = 0
        potentialSeekVideoTimeStart = CMTime.zero
    }

    func enableHeartbeat() {
        let interval = Double(config.heartbeatInterval) / 1_000.0
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(StateMachine.onHeartbeat), userInfo: nil, repeats: true)
    }

    func disableHeartbeat() {
        heartbeatTimer?.invalidate()
    }
    
    func scheduleRebufferHeartbeat() {
        self.rebufferHeartbeatTimer = DispatchWorkItem { [weak self] in
            guard let self = self,
                self.rebufferHeartbeatTimer != nil else {
                return
            }
            self.onHeartbeat()
            self.currentRebufferIntervalIndex = min(self.currentRebufferIntervalIndex + 1, self.rebufferHeartbeatInterval.count - 1)
            self.scheduleRebufferHeartbeat()
        }
        self.rebufferHeartbeatQueue.asyncAfter(deadline: getRebufferDeadline(), execute: self.rebufferHeartbeatTimer!)
    }

    func disableRebufferHeartbeat() {
        self.rebufferHeartbeatQueue.sync {
            self.rebufferHeartbeatTimer?.cancel()
            self.rebufferHeartbeatTimer = nil
            self.currentRebufferIntervalIndex = 0
        }
    }
    
    private func getRebufferDeadline() -> DispatchTime {
        let interval = Double(rebufferHeartbeatInterval[currentRebufferIntervalIndex]) / 1_000.0
        return DispatchTime.now() + interval
    }

    @objc func onHeartbeat() {
        guard let enterTime = enterTimestamp else {
            return
        }
        videoTimeEnd = delegate?.currentTime
        let timestamp = Date().timeIntervalSince1970Millis
        delegate?.stateMachine(self, didHeartbeatWithDuration: timestamp - enterTime)
        videoTimeStart = videoTimeEnd
        enterTimestamp = timestamp
    }
    
    public func getErrorData() -> ErrorData? {
        self.errorData
    }
    
    public func setErrorData(error: ErrorData?) {
        self.errorData = error
    }
}
