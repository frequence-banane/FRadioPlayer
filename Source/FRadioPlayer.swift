//
//  FRadioPlayer.swift
//  FRadioPlayer
//
//  Created by Fethi El Hassasna on 2017-11-11.
//  Copyright © 2017 Fethi El Hassasna (@fethica). All rights reserved.
//

import AVFoundation
import Cache

// MARK: - FRadioPlayingState

/**
 `FRadioPlayingState` is the Player playing state enum
 */

@objc public enum FRadioPlaybackState: Int {
    
    /// Player is playing
    case playing
    
    /// Player is paused
    case paused
    
    /// Player is stopped
    case stopped
    
    /// Return a readable description
    public var description: String {
        switch self {
        case .playing: return "Player is playing"
        case .paused: return "Player is paused"
        case .stopped: return "Player is stopped"
        }
    }
}

// MARK: - FRadioPlayerState

/**
 `FRadioPlayerState` is the Player status enum
 */

@objc public enum FRadioPlayerState: Int {
    
    /// URL not set
    case urlNotSet
    
    /// Player is ready to play
    case readyToPlay
    
    /// Player is loading
    case loading
    
    /// The loading has finished
    case loadingFinished
    
    /// Error with playing
    case error
    
    /// Return a readable description
    public var description: String {
        switch self {
        case .urlNotSet: return "URL is not set"
        case .readyToPlay: return "Ready to play"
        case .loading: return "Loading"
        case .loadingFinished: return "Loading finished"
        case .error: return "Error"
        }
    }
}

public enum FRadioPlayerResource {
    /// A live feed will not be cached
    case liveFeed(URL)
    
    /// A static asset will be cached
    case staticAsset(URL)
}

// MARK: - FRadioPlayerDelegate

/**
 The `FRadioPlayerDelegate` protocol defines methods you can implement to respond to playback events associated with an `FRadioPlayer` object.
 */

public protocol FRadioPlayerDelegate: class {
    /**
     Called when player changes state
     
     - parameter player: FRadioPlayer
     - parameter state: FRadioPlayerState
     */
    func radioPlayer(_ player: FRadioPlayer, playerStateDidChange state: FRadioPlayerState)
    
    /**
     Called when the player changes the playing state
     
     - parameter player: FRadioPlayer
     - parameter state: FRadioPlaybackState
     */
    func radioPlayer(_ player: FRadioPlayer, playbackStateDidChange state: FRadioPlaybackState)
    
    /**
     Called when player changes the current player item
     
     - parameter player: FRadioPlayer
     - parameter url: Radio URL
     */
    func radioPlayer(_ player: FRadioPlayer, itemDidChange resource: FRadioPlayerResource?)
    
    /**
     Called when player item changes the timed metadata value
     
     - parameter player: FRadioPlayer
     - parameter rawValue: metadata raw value
     */
    func radioPlayer(_ player: FRadioPlayer, metadataDidChange rawValue: String?)
    
    /**
     Called when the player gets the artwork for the playing song
     
     - parameter player: FRadioPlayer
     - parameter artworkURL: URL for the artwork from iTunes
     */
    func radioPlayer(_ player: FRadioPlayer, artworkDidChange artworkURL: URL?)
}

public extension FRadioPlayerDelegate {
    func radioPlayer(_ player: FRadioPlayer, itemDidChange resource: FRadioPlayerResource?) {}
    
    func radioPlayer(_ player: FRadioPlayer, metadataDidChange rawValue: String?) {}
    
    func radioPlayer(_ player: FRadioPlayer, artworkDidChange artworkURL: URL?) {}
}

// MARK: - FRadioPlayer

/**
 FRadioPlayer is a wrapper around AVPlayer to handle internet radio playback.
 */

open class FRadioPlayer: NSObject, CachingPlayerItemDelegate {
    
    // MARK: - Properties
    
    /// Returns the singleton `FRadioPlayer` instance.
    public static let shared = FRadioPlayer()
    
    /**
     The delegate object for the `FRadioPlayer`.
     Implement the methods declared by the `FRadioPlayerDelegate` object to respond to user interactions and the player output.
     */
    open weak var delegate: FRadioPlayerDelegate?
    
    /// The player current resource (to be played)
    open var radioResource: FRadioPlayerResource? {
        didSet {
            radioResourceDidChange(with: radioResource)
        }
    }
    
    /// The player starts playing when the radioURL property gets set. (default == true)
    open var isAutoPlay = true
    
    /// Enable fetching albums artwork from the iTunes API. (default == true)
    open var enableArtwork = true
    
    /// Artwork image size. (default == 100 | 100x100)
    open var artworkSize = 100
    
    /// Read only property to get the current AVPlayer rate.
    open var rate: Float? {
        return player?.rate
    }
    
    /// Check if the player is playing
    open var isPlaying: Bool {
        switch playbackState {
        case .playing:
            return true
        case .stopped, .paused:
            return false
        }
    }
    
    /// Player current state of type `FRadioPlayerState`
    open private(set) var state = FRadioPlayerState.urlNotSet {
        didSet {
            guard oldValue != state else { return }
            delegate?.radioPlayer(self, playerStateDidChange: state)
        }
    }
    
    /// Playing state of type `FRadioPlaybackState`
    open private(set) var playbackState = FRadioPlaybackState.stopped {
        didSet {
            guard oldValue != playbackState else { return }
            delegate?.radioPlayer(self, playbackStateDidChange: playbackState)
            let activeState = (playbackState == FRadioPlaybackState.playing) ? true : false
            try? audioSession?.setActive(activeState, options: AVAudioSession.SetActiveOptions.notifyOthersOnDeactivation)
        }
    }
    
    // MARK: - Private properties
    
    /// AVPlayer
    private var player: AVPlayer?
    
    /// Last player item
    private var lastPlayerItem: CachingPlayerItem?
    
    /// Check for headphones, used to handle audio route change
    private var headphonesConnected: Bool = false
    
    /// Seize and release explicit control of audio output
    private var audioSession : AVAudioSession?
    
    /// Show buffering using CachingDelegate
    /// Save even partial content until app closes or memory request
    /// Save full content (obv) until it is listened to
    /// playerItem polymorphism between regular AVPlayerItem and Caching (or make caching able to behave exactly like AVPI, for live listening)
    /// Default player item
    private var playerItem: CachingPlayerItem? {
        didSet {
            playerItemDidChange()
        }
    }
    
    /// Reachability for network interruption handling
    private let reachability = Reachability()!
    
    /// Current network connectivity
    private var isConnected = false
    
    /// Cache configuration
    let diskConfig = DiskConfig(name: "DiskCache")
    let memoryConfig = MemoryConfig(expiry: .never, countLimit: 10, totalCostLimit: 10)
    let dataTransformer = TransformerFactory.forData()
    
    lazy var storage: Cache.Storage? = {
        return try? Cache.Storage(diskConfig: diskConfig, memoryConfig: memoryConfig, transformer: dataTransformer)
    }()
    
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        
        #if !os(macOS)
        let options: AVAudioSession.CategoryOptions
        
        // Enable bluetooth playback
        #if os(iOS)
        options = [.defaultToSpeaker, .allowBluetooth]
        #else
        options = []
        #endif
        
        // Start audio session
        audioSession = AVAudioSession.sharedInstance()
        try? audioSession!.setCategory(AVAudioSession.Category.playback, mode: AVAudioSession.Mode.default, options: options)
        #endif
        
        // Notifications
        setupNotifications()
        
        // Check for headphones
        #if os(iOS)
        checkHeadphonesConnection(outputs: AVAudioSession.sharedInstance().currentRoute.outputs)
        #endif
        
        // Reachability config
        try? reachability.startNotifier()
        NotificationCenter.default.addObserver(self, selector: #selector(reachabilityChanged(note:)), name: .reachabilityChanged, object: reachability)
        isConnected = reachability.connection != .none
    }
    
    // MARK: - Control Methods
    
    /**
     Trigger the play function of the radio player
     
     */
    open func play() {
        guard let player = player else { return }
        if player.currentItem == nil, playerItem != nil {
            player.replaceCurrentItem(with: playerItem)
        }
        
        player.play()
        playbackState = .playing
    }
    
    /**
     Trigger the pause function of the radio player
     
     */
    open func pause() {
        guard let player = player else { return }
        player.pause()
        playbackState = .paused
    }
    
    /**
     Trigger the stop function of the radio player
     
     */
    open func stop() {
        guard let player = player else { return }
        player.replaceCurrentItem(with: nil)
        timedMetadataDidChange(rawValue: nil)
        playbackState = .stopped
    }
    
    /**
     Toggle isPlaying state
     
     */
    open func togglePlaying() {
        isPlaying ? pause() : play()
    }
    
    // MARK: - Private helpers
    
    private func radioResourceDidChange(with resource: FRadioPlayerResource?) {
        resetPlayer()
        
        guard let resource = resource else { state = .urlNotSet; return }
        
        func loadDistantData(url: URL) {
            state = .loading
            preparePlayer(with: AVURLAsset(url: url)) { (success, asset) in
                guard success, let asset = asset else {
                    self.resetPlayer()
                    self.state = .error
                    return
                }
                self.setupPlayer(with: asset)
            }
        }
        
        switch resource {
        case .staticAsset(let url):
            storage?.async.entry(forKey: url.absoluteString, completion: { result in
                switch result {
                case .error: // The track is not cached.
                    loadDistantData(url: url)
                case .value(let entry): // The track is cached.
                    self.setupPlayer(withLocal: entry.object, mimeType: "audio/mpeg", fileExtension: "mp3")
                }
            })
            
        case .liveFeed(let url):
            loadDistantData(url: url)
            
        }
    }
    
    private func setupPlayer(withLocal data: Data, mimeType: String, fileExtension: String) {
        if player == nil {
            player = AVPlayer()
        }
        
        playerItem = CachingPlayerItem(data: data, mimeType: mimeType, fileExtension: fileExtension)
    }
    
    private func setupPlayer(with asset: AVURLAsset) {
        if player == nil {
            player = AVPlayer()
        }
        
        playerItem = CachingPlayerItem(asset: asset)
    }
    
    /** Reset all player item observers and create new ones
     
     */
    private func playerItemDidChange() {
        
        guard lastPlayerItem != playerItem else { return }
        
        if let item = lastPlayerItem {
            pause()
            
            item.delegate = nil
        }
        
        lastPlayerItem = playerItem
        timedMetadataDidChange(rawValue: nil)
        
        if let item = playerItem {
            
            item.delegate = self
            
            player?.replaceCurrentItem(with: item)
            if isAutoPlay { play() }
        }
        
        delegate?.radioPlayer(self, itemDidChange: radioResource)
    }
    
    /** Prepare the player from the passed AVURLAsset
     
     */
    private func preparePlayer(with asset: AVURLAsset?, completionHandler: @escaping (_ isPlayable: Bool, _ asset: AVURLAsset?)->()) {
        guard let asset = asset else {
            completionHandler(false, nil)
            return
        }
        
        let requestedKey = ["playable"]
        
        asset.loadValuesAsynchronously(forKeys: requestedKey) {
            
            DispatchQueue.main.async {
                var error: NSError?
                
                let keyStatus = asset.statusOfValue(forKey: "playable", error: &error)
                if keyStatus == AVKeyValueStatus.failed || !asset.isPlayable {
                    completionHandler(false, nil)
                    return
                }
                
                completionHandler(true, asset)
            }
        }
    }
    
    private func timedMetadataDidChange(rawValue: String?) {
        delegate?.radioPlayer(self, metadataDidChange: rawValue)
        shouldGetArtwork(for: rawValue, enableArtwork)
    }
    
    private func shouldGetArtwork(for rawValue: String?, _ enabled: Bool) {
        guard enabled else { return }
        guard let rawValue = rawValue else {
            self.delegate?.radioPlayer(self, artworkDidChange: nil)
            return
        }
        
        FRadioAPI.getArtwork(for: rawValue, size: artworkSize, completionHandler: { [unowned self] artworlURL in
            DispatchQueue.main.async {
                self.delegate?.radioPlayer(self, artworkDidChange: artworlURL)
            }
        })
    }
    
    private func reloadItem() {
        player?.replaceCurrentItem(with: nil)
        player?.replaceCurrentItem(with: playerItem)
    }
    
    private func resetPlayer() {
        stop()
        playerItem = nil
        lastPlayerItem = nil
        player = nil
    }
    
    deinit {
        resetPlayer()
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Notifications
    
    private func setupNotifications() {
        #if os(iOS)
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
        #endif
    }
    
    // MARK: - Responding to Interruptions
    
    @objc private func handleInterruption(notification: Notification) {
        #if os(iOS)
        guard let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
        }
        switch type {
        case .began:
            DispatchQueue.main.async { self.pause() }
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { break }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            DispatchQueue.main.async { options.contains(.shouldResume) ? self.play() : self.pause() }
        }
        #endif
    }
    
    @objc func reachabilityChanged(note: Notification) {
        
        guard let reachability = note.object as? Reachability else { return }
        
        // Check if the internet connection was lost
        if reachability.connection != .none, !isConnected {
            checkNetworkInterruption()
        }
        
        isConnected = reachability.connection != .none
    }
    
    // Check if the playback could keep up after a network interruption
    private func checkNetworkInterruption() {
        guard
            let item = playerItem,
            !item.isPlaybackLikelyToKeepUp,
            reachability.connection != .none else { return }
        
        player?.pause()
        
        // Wait 1 sec to recheck and make sure the reload is needed
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1) {
            if !item.isPlaybackLikelyToKeepUp { self.reloadItem() }
            self.isPlaying ? self.player?.play() : self.player?.pause()
        }
    }
    
    // MARK: - Responding to Route Changes
    #if os(iOS)
    private func checkHeadphonesConnection(outputs: [AVAudioSessionPortDescription]) {
        for output in outputs where output.portType == .headphones {
            headphonesConnected = true
            break
        }
        headphonesConnected = false
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        
        guard let userInfo = notification.userInfo,
            let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue:reasonValue) else { return }
        
        switch reason {
        case .newDeviceAvailable:
            checkHeadphonesConnection(outputs: AVAudioSession.sharedInstance().currentRoute.outputs)
        case .oldDeviceUnavailable:
            guard let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription else { return }
            checkHeadphonesConnection(outputs: previousRoute.outputs);
            DispatchQueue.main.async { self.headphonesConnected ? () : self.pause() }
        default: break
        }
    }
    #endif
    
    // MARK: - KVO
    
    /// Is called when the media file is fully downloaded.
    func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingData data: Data) {
        
    }
    
    /// Is called every time a new portion of data is received.
    func playerItem(_ playerItem: CachingPlayerItem, didDownloadBytesSoFar bytesDownloaded: Int, outOf bytesExpected: Int) {
        
    }
    
    /// Is called after initial prebuffering is finished, means
    /// we are ready to play.
    func playerItemStatusChanged(_ playerItem: CachingPlayerItem) {
        assert(playerItem == self.playerItem)
        if playerItem.status == AVPlayerItem.Status.readyToPlay {
            self.state = .readyToPlay
        } else if playerItem.status == AVPlayerItem.Status.failed {
            self.state = .error
        }
    }
    
    /// Is called when the data being downloaded did not arrive in time to
    /// continue playback.
    func playerItemPlaybackStalled(_ playerItem: CachingPlayerItem) {
        
    }
    
    /// Is called when the buffer has been totally read.
    func playerItemBufferEmpty(_ playerItem: CachingPlayerItem) {
        assert(playerItem == self.playerItem)
        if playerItem.isPlaybackBufferEmpty {
            self.state = .loading
            self.checkNetworkInterruption()
        }
    }
    
    /// Is called when likelihood of being able to keep playing without
    /// interruption has changed.
    func playerItem(_ playerItem: CachingPlayerItem, isPlaybackLikelyToKeepUp: Bool) {
        assert(playerItem == self.playerItem)
        self.state = isPlaybackLikelyToKeepUp ? .loadingFinished : .loading
    }
    
    /// Is called when the timed metadata has been updated.
    func playerItemTimedMetadataUpdated(_ playerItem: CachingPlayerItem) {
        assert(playerItem == self.playerItem)
        let rawValue = playerItem.timedMetadata?.first?.value as? String
        timedMetadataDidChange(rawValue: rawValue)
    }
    
    /// Is called when the player item has reached the end of its asset.
    func playerItemDidPlayToEndTime(_ playerItem: CachingPlayerItem) {
        
    }
    
    /// Is called on downloading error.
    func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error) {
        
    }
}

