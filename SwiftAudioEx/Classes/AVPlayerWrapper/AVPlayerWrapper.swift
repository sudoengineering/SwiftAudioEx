//
//  AVPlayerWrapper.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 06/03/2018.
//  Copyright © 2018 Jørgen Henrichsen. All rights reserved.
//

import Foundation
import AVFoundation
import MediaPlayer
import Accelerate

public enum PlaybackEndedReason: String {
    case playedUntilEnd
    case playerStopped
    case skippedToNext
    case skippedToPrevious
    case jumpedToIndex
}

class AVPlayerWrapper: AVPlayerWrapperProtocol {
    
    struct Constants {
        static let assetPlayableKey = "playable"
    }
    
    // MARK: - Properties
    
    var avPlayer: AVPlayer
    let playerObserver: AVPlayerObserver
    let playerTimeObserver: AVPlayerTimeObserver
    let playerItemNotificationObserver: AVPlayerItemNotificationObserver
    let playerItemObserver: AVPlayerItemObserver
    
    public var decibels: Float = 0
    public var frequencies: [Float] = []
    
    // https://gist.github.com/omarojo/03d08165a1a7962cb30c17ec01f809a3
    var tap: Unmanaged<MTAudioProcessingTap>?
    var audioProcessingFormat:  AudioStreamBasicDescription?//UnsafePointer<AudioStreamBasicDescription>?
    
    /**
     True if the last call to load(from:playWhenReady) had playWhenReady=true.
     */
    fileprivate var _playWhenReady: Bool = true
    fileprivate var _initialTime: TimeInterval?
    
    /// True when the track was paused for the purpose of switching tracks
    fileprivate var _pausedForLoad: Bool = false
    
    fileprivate var _state: AVPlayerWrapperState = AVPlayerWrapperState.idle {
        didSet {
            if oldValue != _state {
                self.delegate?.AVWrapper(didChangeState: _state)
            }
        }
    }
    
    public init() {
        self.avPlayer = AVPlayer()
        self.playerObserver = AVPlayerObserver()
        self.playerObserver.player = avPlayer
        self.playerTimeObserver = AVPlayerTimeObserver(periodicObserverTimeInterval: timeEventFrequency.getTime())
        self.playerTimeObserver.player = avPlayer
        self.playerItemNotificationObserver = AVPlayerItemNotificationObserver()
        self.playerItemObserver = AVPlayerItemObserver()
        
        self.playerObserver.delegate = self
        self.playerTimeObserver.delegate = self
        self.playerItemNotificationObserver.delegate = self
        self.playerItemObserver.delegate = self
        
        // disabled since we're not making use of video playback
        self.avPlayer.allowsExternalPlayback = false;
        
        playerTimeObserver.registerForPeriodicTimeEvents()
    }
    
    class TapCookie {
        weak var input : AVPlayerWrapper?
        
        deinit {
            print("TapCookie deinit")
        }
    }
    
    //MARK: GET AUDIO BUFFERS
    func setupProcessingTap(){
        let cookie = TapCookie()
        cookie.input = self
        
        let playerItem = avPlayer.currentItem!
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(cookie).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess)
        
        var tap: Unmanaged<MTAudioProcessingTap>?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        self.tap = tap
        
        if err == noErr {
        }
        
        let audioTrack = playerItem.asset.tracks(withMediaType: AVMediaType.audio).first!
        let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
        inputParams.audioTapProcessor = tap?.takeUnretainedValue()
        tap?.release()
        
        // print("inputParms: \(inputParams), \(inputParams.audioTapProcessor)\n")
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [inputParams]
        
        playerItem.audioMix = audioMix
    }
    
    //MARK: TAP CALLBACKS
    
    let tapInit: MTAudioProcessingTapInitCallback = {
        (tap, clientInfo, tapStorageOut) in
        tapStorageOut.pointee = clientInfo
        
        print("init \n")
        
    }
    
    let tapFinalize: MTAudioProcessingTapFinalizeCallback = {
        (tap) in
        print("finalize \(tap)\n")
        
        Unmanaged<TapCookie>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
    }
    
    let tapPrepare: MTAudioProcessingTapPrepareCallback = {
        (tap, itemCount, basicDescription) in
        print("prepare: \n")
        let cookie = Unmanaged<TapCookie>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        let selfMediaInput = cookie.input!
        
        selfMediaInput.audioProcessingFormat = AudioStreamBasicDescription(mSampleRate: basicDescription.pointee.mSampleRate,
                                                                           mFormatID: basicDescription.pointee.mFormatID, mFormatFlags: basicDescription.pointee.mFormatFlags, mBytesPerPacket: basicDescription.pointee.mBytesPerPacket, mFramesPerPacket: basicDescription.pointee.mFramesPerPacket, mBytesPerFrame: basicDescription.pointee.mBytesPerFrame, mChannelsPerFrame: basicDescription.pointee.mChannelsPerFrame, mBitsPerChannel: basicDescription.pointee.mBitsPerChannel, mReserved: basicDescription.pointee.mReserved)
    }
    
    let tapUnprepare: MTAudioProcessingTapUnprepareCallback = {
        (tap) in
        print("unprepare \(tap)\n")
    }
    
    let tapProcess: MTAudioProcessingTapProcessCallback = {
        (tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut) in
        let cookie = Unmanaged<TapCookie>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        guard let selfMediaInput = cookie.input else {
            print("Tap callback: AVPlayerWrapper was deallocated!")
            return
        }
        
        let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
        if status != noErr {
            print("Error TAPGetSourceAudio :\(String(describing: status.description))")
            return
        }
        
        if #available(iOS 13.0, *) {
            selfMediaInput.processAudioData(audioData: bufferListInOut, framesNumber: UInt32(numberFrames))
        } else {
            // Fallback on earlier versions
        }
    }
    //??
    @available(iOS 13.0, *)
    func processAudioData(audioData: UnsafeMutablePointer<AudioBufferList>, framesNumber: UInt32) {
        var sbuf: CMSampleBuffer?
        var status : OSStatus?
        var format: CMFormatDescription?
        
        
        
        //FORMAT
        //           var audioFormat = self.audioProcessingFormat?.pointee
        guard var audioFormat = self.audioProcessingFormat else {
            return
        }
        
        status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &audioFormat, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        
        if status != noErr {
            print("Error CMAudioFormatDescriptionCreater :\(String(describing: status?.description))")
            return
        }
        
        var timing = CMSampleTimingInfo(duration: CMTimeMake(value: 1, timescale: Int32(audioFormat.mSampleRate)), presentationTimeStamp: self.avPlayer.currentTime(), decodeTimeStamp: CMTime.invalid)
        
        
        //?? Create an empty sample buffer `sbuf`
        status = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                      dataBuffer: nil,
                                      dataReady: Bool(truncating: 0),
                                      makeDataReadyCallback: nil,
                                      refcon: nil,
                                      formatDescription: format,
                                      sampleCount: CMItemCount(framesNumber),
                                      sampleTimingEntryCount: 1,
                                      sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                      sampleBufferOut: &sbuf);
        if status != noErr {
            print("Error CMSampleBufferCreate :\(String(describing: status?.description))")
            return
        }
        
        //?? Copy all the data into the sbuf sample buffer from audioData that got passed in
//        status =   CMSampleBufferSetDataBufferFromAudioBufferList(sbuf!,
//                                                                  blockBufferAllocator: kCFAllocatorDefault ,
//                                                                  blockBufferMemoryAllocator: kCFAllocatorDefault,
//                                                                  flags: 0,
//                                                                  bufferList: audioData)
                   let data = Data(bytes: audioData.pointee.mBuffers.mData!, count: Int(audioData.pointee.mBuffers.mDataByteSize))

        //Convert to typed Float32 array
        let samples = data.withUnsafeBytes {
            UnsafeBufferPointer<Float32>(start: $0.baseAddress?.assumingMemoryBound(to: Float32.self) , count: data.count / MemoryLayout<Float32>.size)
        }
        //Convert to Float Array
        let count = samples.count
        var floats: [Float] = Array(repeating: 0.0, count: count)
        
        //?? Can we do this with SIMD?
        for i in 0..<count {
            floats[i] = (samples[i] / 2.0 + 0.5) * 256.0
        }
        //Initiate FFT
        self.frequencies = floats
        
        if status != noErr {
            print("Error cCMSampleBufferSetDataBufferFromAudioBufferList :\(String(describing: status?.description))")
            return
        }
    }
    
    // MARK: - AVPlayerWrapperProtocol
    
    var state: AVPlayerWrapperState {
        return _state
    }
    
    var reasonForWaitingToPlay: AVPlayer.WaitingReason? {
        return avPlayer.reasonForWaitingToPlay
    }
    
    var currentItem: AVPlayerItem? {
        return avPlayer.currentItem
    }
    
    var _pendingAsset: AVAsset? = nil
    
    var automaticallyWaitsToMinimizeStalling: Bool {
        get { return avPlayer.automaticallyWaitsToMinimizeStalling }
        set { avPlayer.automaticallyWaitsToMinimizeStalling = newValue }
    }
    
    var currentTime: TimeInterval {
        let seconds = avPlayer.currentTime().seconds
        return seconds.isNaN ? 0 : seconds
    }
    
    var duration: TimeInterval {
        if let seconds = currentItem?.asset.duration.seconds, !seconds.isNaN {
            return seconds
        }
        else if let seconds = currentItem?.duration.seconds, !seconds.isNaN {
            return seconds
        }
        else if let seconds = currentItem?.loadedTimeRanges.first?.timeRangeValue.duration.seconds,
                !seconds.isNaN {
            return seconds
        }
        return 0.0
    }
    
    var bufferedPosition: TimeInterval {
        return currentItem?.loadedTimeRanges.last?.timeRangeValue.end.seconds ?? 0
    }
    
    weak var delegate: AVPlayerWrapperDelegate? = nil
    
    var bufferDuration: TimeInterval = 0
    
    var timeEventFrequency: TimeEventFrequency = .everySecond {
        didSet {
            playerTimeObserver.periodicObserverTimeInterval = timeEventFrequency.getTime()
        }
    }
    
    var rate: Float {
        get { return avPlayer.rate }
        set { avPlayer.rate = newValue }
    }
    
    var volume: Float {
        get { return avPlayer.volume }
        set { avPlayer.volume = newValue }
    }
    
    var isMuted: Bool {
        get { return avPlayer.isMuted }
        set { avPlayer.isMuted = newValue }
    }
    
    func play() {
        _playWhenReady = true
        avPlayer.play()
    }
    
    func pause() {
        _playWhenReady = false
        avPlayer.pause()
    }
    
    func togglePlaying() {
        switch avPlayer.timeControlStatus {
        case .playing, .waitingToPlayAtSpecifiedRate:
            pause()
        case .paused:
            play()
        @unknown default:
            fatalError("Unknown AVPlayer.timeControlStatus")
        }
    }
    
    func stop() {
        pause()
        reset(soft: false)
    }
    
    func seek(to seconds: TimeInterval) {
        avPlayer.seek(to: CMTimeMakeWithSeconds(seconds, preferredTimescale: 1000)) { (finished) in
            if let _ = self._initialTime {
                self._initialTime = nil
                if self._playWhenReady {
                    self.play()
                }
            }
            self.delegate?.AVWrapper(seekTo: Int(seconds), didFinish: finished)
        }
    }
    
    func load(from url: URL, playWhenReady: Bool, options: [String: Any]? = nil) {
        reset(soft: true)
        _playWhenReady = playWhenReady
        
        if currentItem?.status == .failed {
            recreateAVPlayer()
        }
        
        self._pendingAsset = AVURLAsset(url: url, options: options)
        
        if let pendingAsset = _pendingAsset {
            self._state = .loading
            pendingAsset.loadValuesAsynchronously(forKeys: [Constants.assetPlayableKey], completionHandler: { [weak self] in
                
                guard let self = self else {
                    return
                }
                
                var error: NSError? = nil
                let status = pendingAsset.statusOfValue(forKey: Constants.assetPlayableKey, error: &error)
                
                DispatchQueue.main.async {
                    let isPendingAsset = (self._pendingAsset != nil && pendingAsset.isEqual(self._pendingAsset))
                    switch status {
                    case .loaded:
                        if isPendingAsset {
                            let currentItem = AVPlayerItem(asset: pendingAsset, automaticallyLoadedAssetKeys: [Constants.assetPlayableKey])
                            currentItem.preferredForwardBufferDuration = self.bufferDuration
                            self.avPlayer.replaceCurrentItem(with: currentItem)
                            self.setupProcessingTap()
                            
                            // Register for events
                            self.playerTimeObserver.registerForBoundaryTimeEvents()
                            self.playerObserver.startObserving()
                            self.playerItemNotificationObserver.startObserving(item: currentItem)
                            self.playerItemObserver.startObserving(item: currentItem)
                            for format in pendingAsset.availableMetadataFormats {
                                self.delegate?.AVWrapper(didReceiveMetadata: pendingAsset.metadata(forFormat: format))
                            }
                        }
                        break
                        
                    case .failed:
                        if isPendingAsset {
                            self.delegate?.AVWrapper(failedWithError: error)
                            self._pendingAsset = nil
                        }
                        break
                        
                    case .cancelled:
                        break
                        
                    default:
                        break
                    }
                }
            })
        }
    }
    
    func load(from url: URL, playWhenReady: Bool, initialTime: TimeInterval? = nil, options: [String : Any]? = nil) {
        _initialTime = initialTime
        
        _pausedForLoad = true
        self.pause()
        
        self.load(from: url, playWhenReady: playWhenReady, options: options)
    }
    
    // MARK: - Util
    
    private func reset(soft: Bool) {
        playerItemObserver.stopObservingCurrentItem()
        playerTimeObserver.unregisterForBoundaryTimeEvents()
        playerItemNotificationObserver.stopObservingCurrentItem()
        
        self._pendingAsset?.cancelLoading()
        self._pendingAsset = nil
        
        if !soft {
            avPlayer.replaceCurrentItem(with: nil)
        }
    }
    
    /// Will recreate the AVPlayer instance. Used when the current one fails.
    private func recreateAVPlayer() {
        let player = AVPlayer()
        playerObserver.player = player
        playerTimeObserver.player = player
        playerTimeObserver.registerForPeriodicTimeEvents()
        avPlayer = player
        delegate?.AVWrapperDidRecreateAVPlayer()
    }
    
}

extension AVPlayerWrapper: AVPlayerObserverDelegate {
    
    // MARK: - AVPlayerObserverDelegate
    
    func player(didChangeTimeControlStatus status: AVPlayer.TimeControlStatus) {
        switch status {
        case .paused:
            if currentItem == nil {
                _state = .idle
            }
            else if _pausedForLoad == true {}
            else {
                self._state = .paused
            }
        case .waitingToPlayAtSpecifiedRate:
            self._state = .buffering
        case .playing:
            self._state = .playing
        @unknown default:
            break
        }
    }
    
    func player(statusDidChange status: AVPlayer.Status) {
        switch status {
        case .readyToPlay:
            self._state = .ready
            self._pausedForLoad = false
            if _playWhenReady && (_initialTime ?? 0) == 0 {
                self.play()
            }
            else if let initialTime = _initialTime {
                self.seek(to: initialTime)
            }
            break
            
        case .failed:
            self.delegate?.AVWrapper(failedWithError: avPlayer.error)
            break
            
        case .unknown:
            break
        @unknown default:
            break
        }
    }
    
}

extension AVPlayerWrapper: AVPlayerTimeObserverDelegate {
    
    // MARK: - AVPlayerTimeObserverDelegate
    
    func audioDidStart() {
        self._state = .playing
    }
    
    func timeEvent(time: CMTime) {
        self.delegate?.AVWrapper(secondsElapsed: time.seconds)
    }
    
}

extension AVPlayerWrapper: AVPlayerItemNotificationObserverDelegate {
    
    // MARK: - AVPlayerItemNotificationObserverDelegate
    
    func itemDidPlayToEndTime() {
        delegate?.AVWrapperItemDidPlayToEndTime()
    }
    
}

extension AVPlayerWrapper: AVPlayerItemObserverDelegate {
    
    // MARK: - AVPlayerItemObserverDelegate
    
    func item(didUpdateDuration duration: Double) {
        self.delegate?.AVWrapper(didUpdateDuration: duration)
    }
    
    func item(didReceiveMetadata metadata: [AVMetadataItem]) {
        self.delegate?.AVWrapper(didReceiveMetadata: metadata)
    }
    
}
