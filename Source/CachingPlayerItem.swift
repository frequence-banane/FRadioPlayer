//
//  CachingPlayerItem.swift
//  
//
//  Copyright Nikita Belousov
//  Portions Copyright Perceval FARAMAZ
//
//  Fetched from http://github.com/neekeetab/CachingPlayerItem on 21.03.19

import Foundation
import AVFoundation

fileprivate extension URL {
    
    func withScheme(_ scheme: String) -> URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        return components?.url
    }
    
}

internal protocol CachingPlayerItemDelegate : class {
    
    /// Is called when the media file is fully downloaded.
    func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingData data: Data)
    
    /// Is called every time a new portion of data is received.
    func playerItem(_ playerItem: CachingPlayerItem, didDownloadBytesSoFar bytesDownloaded: Int, outOf bytesExpected: Int)
    
    /// Is called after initial prebuffering is finished, means
    /// we are ready to play.
    func playerItemStatusChanged(_ playerItem: CachingPlayerItem)
    
    /// Is called when the data being downloaded did not arrive in time to
    /// continue playback.
    func playerItemPlaybackStalled(_ playerItem: CachingPlayerItem)
    
    /// Is called when the buffer has been totally read.
    func playerItemBufferEmpty(_ playerItem: CachingPlayerItem)
    
    /// Is called when likelihood of being able to keep playing without
    /// interruption has changed.
    func playerItem(_ playerItem: CachingPlayerItem, isPlaybackLikelyToKeepUp: Bool)
    
    /// Is called when the timed metadata has been updated.
    func playerItemTimedMetadataUpdated(_ playerItem: CachingPlayerItem)
    
    /// Is called when the player item has reached the end of its asset.
    func playerItemDidPlayToEndTime(_ playerItem: CachingPlayerItem)
    
    /// Is called on downloading error.
    func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error)
    
}

internal extension CachingPlayerItemDelegate {
    func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingData data: Data) {}
    func playerItem(_ playerItem: CachingPlayerItem, didDownloadBytesSoFar bytesDownloaded: Int, outOf bytesExpected: Int) {}
    func playerItemStatusChanged(_ playerItem: CachingPlayerItem) {}
    func playerItemPlaybackStalled(_ playerItem: CachingPlayerItem) {}
    func playerItemBufferEmpty(_ playerItem: CachingPlayerItem) {}
    func playerItem(_ playerItem: CachingPlayerItem, isPlaybackLikelyToKeepUp: Bool) {}
    func playerItemTimedMetadataUpdated(_ playerItem: CachingPlayerItem) {}
    func playerItemDidPlayToEndTime(_ playerItem: CachingPlayerItem) {}
    func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error) {}
}

class CachingURLAsset: AVURLAsset {
    var isLive = false
}

class ResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, URLSessionDelegate, URLSessionDataDelegate, URLSessionTaskDelegate {
    
    var playingFromData = false
    var mimeType: String? // is required when playing from Data
    var session: URLSession?
    var mediaData: Data?
    var response: URLResponse?
    var pendingRequests = Set<AVAssetResourceLoadingRequest>()
    weak var owner: CachingPlayerItem?
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        
        if playingFromData {
            
            // Nothing to load.
            
        } else if session == nil {
            
            // If we're playing from a url, we need to download the file.
            // We start loading the file on first request only.
            guard let initialUrl = owner?.url else {
                fatalError("internal inconsistency")
            }
            
            startDataRequest(with: initialUrl)
        }
        
        pendingRequests.insert(loadingRequest)
        processPendingRequests()
        return true
        
    }
    
    func startDataRequest(with url: URL) {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        session?.dataTask(with: url).resume()
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pendingRequests.remove(loadingRequest)
    }
    
    // MARK: URLSession delegate
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        mediaData?.append(data)
        processPendingRequests()
        owner?.delegate?.playerItem(owner!, didDownloadBytesSoFar: mediaData!.count, outOf: Int(dataTask.countOfBytesExpectedToReceive))
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(Foundation.URLSession.ResponseDisposition.allow)
        mediaData = Data()
        self.response = response
        processPendingRequests()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let errorUnwrapped = error {
            owner?.delegate?.playerItem(owner!, downloadingFailedWith: errorUnwrapped)
            return
        }
        processPendingRequests()
        owner?.delegate?.playerItem(owner!, didFinishDownloadingData: mediaData!)
    }
    
    // MARK: -
    
    func processPendingRequests() {
        
        // get all fullfilled requests
        let requestsFulfilled = Set<AVAssetResourceLoadingRequest>(pendingRequests.compactMap {
            self.fillInContentInformationRequest($0.contentInformationRequest)
            if self.haveEnoughDataToFulfillRequest($0.dataRequest!) {
                $0.finishLoading()
                return $0
            }
            return nil
        })
        
        // remove fulfilled requests from pending requests
        _ = requestsFulfilled.map { self.pendingRequests.remove($0) }
        
    }
    
    func fillInContentInformationRequest(_ contentInformationRequest: AVAssetResourceLoadingContentInformationRequest?) {
        
        // if we play from Data we make no url requests, therefore we have no responses, so we need to fill in contentInformationRequest manually
        if playingFromData {
            contentInformationRequest?.contentType = self.mimeType
            contentInformationRequest?.contentLength = Int64(mediaData!.count)
            contentInformationRequest?.isByteRangeAccessSupported = true
            return
        }
        
        guard let responseUnwrapped = response else {
            // have no response from the server yet
            return
        }
        
        contentInformationRequest?.contentType = responseUnwrapped.mimeType
        contentInformationRequest?.contentLength = responseUnwrapped.expectedContentLength
        contentInformationRequest?.isByteRangeAccessSupported = true
        
    }
    
    func haveEnoughDataToFulfillRequest(_ dataRequest: AVAssetResourceLoadingDataRequest) -> Bool {
        
        let requestedOffset = Int(dataRequest.requestedOffset)
        let requestedLength = dataRequest.requestedLength
        let currentOffset = Int(dataRequest.currentOffset)
        
        guard let songDataUnwrapped = mediaData,
            songDataUnwrapped.count > currentOffset else {
                // Don't have any data at all for this request.
                return false
        }
        
        let bytesToRespond = min(songDataUnwrapped.count - currentOffset, requestedLength)
        let dataToRespond = songDataUnwrapped.subdata(in: Range(uncheckedBounds: (currentOffset, currentOffset + bytesToRespond)))
        dataRequest.respond(with: dataToRespond)
        
        return songDataUnwrapped.count >= requestedLength + requestedOffset
        
    }
    
    deinit {
        session?.invalidateAndCancel()
    }
    
}

open class CachingPlayerItem: AVPlayerItem {
    
    fileprivate let resourceLoaderDelegate = ResourceLoaderDelegate()
    internal let url: URL
    fileprivate let initialScheme: String?
    fileprivate var customFileExtension: String?
    
    weak var delegate: CachingPlayerItemDelegate?
    
    open func download() {
        if resourceLoaderDelegate.session == nil {
            resourceLoaderDelegate.startDataRequest(with: url)
        }
    }
    
    internal static let cachingPlayerItemScheme = "cachingPlayerItemScheme"
    
    
    override init(asset: AVAsset, automaticallyLoadedAssetKeys: [String]?) {
        guard var urlAsset = asset as? CachingURLAsset else { fatalError("Not a CachingURLAsset") }
        let url = urlAsset.url
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme else {
                fatalError("Urls without a scheme are not supported")
        }
        
        self.url = urlAsset.url
        self.initialScheme = scheme
        
        if !urlAsset.isLive {
            guard var urlWithCustomScheme = url.withScheme(CachingPlayerItem.cachingPlayerItemScheme) else {
                fatalError("Urls without a scheme are not supported")
            }
            
            if let ext = customFileExtension {
                urlWithCustomScheme.deletePathExtension()
                urlWithCustomScheme.appendPathExtension(ext)
                self.customFileExtension = ext
            }
            
            urlAsset = CachingURLAsset(url: urlWithCustomScheme)
            urlAsset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: DispatchQueue.main)
        }
        
        super.init(asset: urlAsset, automaticallyLoadedAssetKeys: automaticallyLoadedAssetKeys)
        
        resourceLoaderDelegate.owner = self
        
        registerObservers()
    }
    
    convenience init(url URL: URL, automaticallyLoadedAssetKeys: [String]?, isLive: Bool) {
        let asset = CachingURLAsset(url: URL)
        asset.isLive = isLive
        self.init(asset: asset, automaticallyLoadedAssetKeys: automaticallyLoadedAssetKeys)
    }
    
    /*/// Override/append custom file extension to URL path.
    /// This is required for the player to work correctly with the intended file type.
    init(url: URL, customFileExtension: String?) {
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme,
            var urlWithCustomScheme = url.withScheme(CachingPlayerItem.cachingPlayerItemScheme) else {
                fatalError("Urls without a scheme are not supported")
        }
        
        self.url = url
        self.initialScheme = scheme
        
        if let ext = customFileExtension {
            urlWithCustomScheme.deletePathExtension()
            urlWithCustomScheme.appendPathExtension(ext)
            self.customFileExtension = ext
        }
        
        let asset = CachingURLAsset(url: urlWithCustomScheme)
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: DispatchQueue.main)
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
        
        resourceLoaderDelegate.owner = self
        
        registerObservers()
        
    }*/
    
    /// Is used for playing from Data.
    init(data: Data, mimeType: String, fileExtension: String) {
        guard let fakeUrl = URL(string: CachingPlayerItem.cachingPlayerItemScheme + "://whatever/file.\(fileExtension)") else {
            fatalError("internal inconsistency")
        }
        
        self.url = fakeUrl
        self.initialScheme = nil
        
        resourceLoaderDelegate.mediaData = data
        resourceLoaderDelegate.playingFromData = true
        resourceLoaderDelegate.mimeType = mimeType
        
        let asset = CachingURLAsset(url: fakeUrl)
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: DispatchQueue.main)
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
        resourceLoaderDelegate.owner = self
        
        registerObservers()
    }
    
    // MARK: KVO
    
    func registerObservers() {
        //
        addObserver(self, forKeyPath: #keyPath(CachingPlayerItem.status), options: .new, context: nil)
        addObserver(self, forKeyPath: #keyPath(CachingPlayerItem.isPlaybackBufferEmpty), options: .new, context: nil)
        addObserver(self, forKeyPath: #keyPath(CachingPlayerItem.isPlaybackLikelyToKeepUp), options: .new, context: nil)
        addObserver(self, forKeyPath: #keyPath(CachingPlayerItem.timedMetadata), options: .new, context: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(playbackStalledHandler(notification:)), name:NSNotification.Name.AVPlayerItemPlaybackStalled, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(playbackDidPlayToEndTime(notification:)), name:NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: self)
    }
    
    override open func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        if let item = object as? AVPlayerItem, let keyPath = keyPath, item == self {
            
            switch keyPath {
                
            case #keyPath(CachingPlayerItem.status):
                delegate?.playerItemStatusChanged(self)
                
            case #keyPath(CachingPlayerItem.isPlaybackBufferEmpty):
                delegate?.playerItemBufferEmpty(self)
                
            case #keyPath(CachingPlayerItem.isPlaybackLikelyToKeepUp):
                delegate?.playerItem(self, isPlaybackLikelyToKeepUp: self.isPlaybackLikelyToKeepUp)
                
            case #keyPath(CachingPlayerItem.timedMetadata):
                delegate?.playerItemTimedMetadataUpdated(self)
                
            default:
                break
            }
        }
    }
    
    // MARK: Notification hanlers
    
    @objc func playbackStalledHandler(notification: Notification) {
        guard let object = notification.userInfo,
            let obj = object["object"] as? CachingPlayerItem,
            obj == self
            else { return }
        
        delegate?.playerItemPlaybackStalled(self)
    }
    
    @objc func playbackDidPlayToEndTime(notification: Notification) {
        guard let object = notification.userInfo,
            let obj = object["object"] as? CachingPlayerItem,
            obj == self
            else { return }
        
        delegate?.playerItemDidPlayToEndTime(self)
    }
    
    // MARK: -
    
    deinit {
        removeObserver(self, forKeyPath: #keyPath(CachingPlayerItem.status))
        removeObserver(self, forKeyPath: #keyPath(CachingPlayerItem.isPlaybackBufferEmpty))
        removeObserver(self, forKeyPath: #keyPath(CachingPlayerItem.isPlaybackLikelyToKeepUp))
        removeObserver(self, forKeyPath: #keyPath(CachingPlayerItem.timedMetadata))
        
        NotificationCenter.default.removeObserver(self)
        
        resourceLoaderDelegate.session?.invalidateAndCancel()
    }
    
}
