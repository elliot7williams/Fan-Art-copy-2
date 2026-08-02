//
//  Flowerart.swift
//  Flowering Flow
//
//  Created by Elliot Williams on 2025-07-04.
//

import SwiftUI
import MediaPlayer
import AVFoundation
import CoreImage.CIFilterBuiltins
import UIImageColors

// MARK: - Advanced Image Cache Manager

class ImageCacheManager: ObservableObject {
    static let shared = ImageCacheManager()
    
    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCacheURL: URL
    private let maxMemoryCacheSize: Int = 100 * 1024 * 1024 // 100MB
    private let maxDiskCacheSize: Int = 500 * 1024 * 1024 // 500MB
    private let cacheQueue = DispatchQueue(label: "ImageCacheQueue", qos: .userInitiated)
    
    // Batch write optimization
    private var pendingWrites: [String: UIImage] = [:]
    private var batchWriteTimer: Timer?
    private let batchWriteInterval: TimeInterval = 2.0 // Batch writes every 2 seconds
    
    private init() {
        // Setup disk cache directory
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheURL = cacheDir.appendingPathComponent("FloweringFlowImageCache")
        
        // Create cache directory if it doesn't exist
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        
        // Configure memory cache
        memoryCache.totalCostLimit = maxMemoryCacheSize
        memoryCache.countLimit = 100 // Max 100 images in memory
        
        // Clean up old cache on init
        Task {
            await cleanupOldCache()
        }
        
        // Start batch write timer
        startBatchWriteTimer()
    }
    
    private func startBatchWriteTimer() {
        batchWriteTimer = Timer.scheduledTimer(withTimeInterval: batchWriteInterval, repeats: true) { [weak self] _ in
            self?.performBatchWrites()
        }
    }
    
    private func performBatchWrites() {
        cacheQueue.async {
            for (albumId, image) in self.pendingWrites {
                let diskURL = self.diskCacheURL.appendingPathComponent("\(albumId).jpg")
                if let imageData = image.jpegData(compressionQuality: 0.8) {
                    try? imageData.write(to: diskURL)
                }
            }
            self.pendingWrites.removeAll()
        }
    }
    
    func getImage(for albumId: String) -> UIImage? {
        let key = NSString(string: albumId)
        
        // Check memory cache first
        if let cachedImage = memoryCache.object(forKey: key) {
            return cachedImage
        }
        
        // Check disk cache
        let diskURL = diskCacheURL.appendingPathComponent("\(albumId).jpg")
        if let diskImage = UIImage(contentsOfFile: diskURL.path) {
            // Store back in memory cache
            let cost = Int(diskImage.size.width * diskImage.size.height * 4) // Approximate memory cost
            memoryCache.setObject(diskImage, forKey: key, cost: cost)
            return diskImage
        }
        
        return nil
    }
    
    func setImage(_ image: UIImage, for albumId: String) {
        let key = NSString(string: albumId)
        let cost = Int(image.size.width * image.size.height * 4)
        
        // Store in memory cache
        memoryCache.setObject(image, forKey: key, cost: cost)
        
        // Queue up for batch write to disk
        DispatchQueue.main.async {
            self.pendingWrites[albumId] = image
        }
    }
    
    func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }
    
    private func cleanupOldCache() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // Clean up old disk cache files (older than 7 days)
                let fileManager = FileManager.default
                let cutoffDate = Date().addingTimeInterval(-7 * 24 * 60 * 60) // 7 days ago
                
                if let files = try? fileManager.contentsOfDirectory(at: self.diskCacheURL, includingPropertiesForKeys: [.contentModificationDateKey]) {
                    for file in files {
                        if let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                           let modificationDate = attributes[.modificationDate] as? Date,
                           modificationDate < cutoffDate {
                            try? fileManager.removeItem(at: file)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Model

struct MusicAlbum: Identifiable {
    let id: String
    let title: String
    let artist: String
    private var _artwork: UIImage?
    var colors: [Color] = []
    let songs: [MPMediaItem]
    
    // Lazy loading properties with optimized caching
    var artwork: UIImage? {
        get {
            if let cachedArtwork = _artwork {
                return cachedArtwork
            }
            return ImageCacheManager.shared.getImage(for: id)
        }
        set {
            _artwork = newValue
            if let artwork = newValue {
                ImageCacheManager.shared.setImage(artwork, for: id)
            }
        }
    }
    
    var hasLoadedArtwork: Bool { artwork != nil }
    var hasLoadedColors: Bool { colors.count > 2 || (colors.count == 2 && colors != [Color.gray, Color.black]) }
    
    // Optimized initializer
    init(id: String, title: String, artist: String, artwork: UIImage? = nil, colors: [Color] = [Color.gray, Color.black], songs: [MPMediaItem]) {
        self.id = id
        self.title = title
        self.artist = artist
        self._artwork = artwork
        self.colors = colors
        self.songs = songs
    }
}

// MARK: - Audio Player Manager

class AudioPlayerManager: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTrack: MPMediaItem?
    @Published var playbackProgress: Double = 0.0
    @Published var currentTrackIndex = 0
    var currentAlbumId: String = ""
    
    // Use MPMusicPlayerController for proper music library playback
    private let musicPlayer = MPMusicPlayerController.applicationQueuePlayer
    private var progressTimer: Timer?
    
    init() {
        setupMusicPlayerObservers()
    }
    
    deinit {
        cleanup()
    }
    
    private func cleanup() {
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    private func setupMusicPlayerObservers() {
        musicPlayer.beginGeneratingPlaybackNotifications()
        
        // Playback state observer
        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: musicPlayer,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = self?.musicPlayer.playbackState == .playing
        }
        
        // Now playing item observer
        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: musicPlayer,
            queue: .main
        ) { [weak self] _ in
            self?.currentTrack = self?.musicPlayer.nowPlayingItem
            self?.updateCurrentTrackInfo()
        }
        
        // Start progress timer
        startProgressTimer()
    }
    
    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let currentItem = self.musicPlayer.nowPlayingItem else { return }
            
            let currentTime = self.musicPlayer.currentPlaybackTime
            let duration = currentItem.playbackDuration
            
            if duration > 0 {
                self.playbackProgress = currentTime / duration
            }
        }
    }
    
    private func updateCurrentTrackInfo() {
        // This can be implemented to update album context if needed
        // For now, just update the current track
        currentTrack = musicPlayer.nowPlayingItem
    }
    
    func playTrack(_ track: MPMediaItem) {
        let collection = MPMediaItemCollection(items: [track])
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: collection)
        
        musicPlayer.setQueue(with: descriptor)
        musicPlayer.nowPlayingItem = track
        musicPlayer.play()
        
        currentTrack = track
        isPlaying = true
        playbackProgress = 0.0
        
        print("Playing track: \(track.title ?? "Unknown") by \(track.artist ?? "Unknown")")
    }
    
    func playAlbum(_ songs: [MPMediaItem], startingAt index: Int = 0) {
        guard !songs.isEmpty, index >= 0, index < songs.count else { return }
        
        let collection = MPMediaItemCollection(items: songs)
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: collection)
        
        musicPlayer.setQueue(with: descriptor)
        musicPlayer.nowPlayingItem = songs[index]
        musicPlayer.play()
        
        currentTrack = songs[index]
        currentTrackIndex = index
        isPlaying = true
        playbackProgress = 0.0
        
        print("Playing album starting with: \(songs[index].title ?? "Unknown")")
    }
    
    func pause() {
        musicPlayer.pause()
        isPlaying = false
    }
    
    func resume() {
        musicPlayer.play()
        isPlaying = true
    }
    
    func stop() {
        musicPlayer.stop()
        currentTrack = nil
        isPlaying = false
        playbackProgress = 0.0
        currentTrackIndex = 0
    }
    
    func skipToNext() {
        musicPlayer.skipToNextItem()
    }
    
    func skipToPrevious() {
        musicPlayer.skipToPreviousItem()
    }
    
    func seekTo(progress: Double) {
        guard let currentItem = musicPlayer.nowPlayingItem else { return }
        
        let duration = currentItem.playbackDuration
        let targetTime = duration * progress
        
        musicPlayer.currentPlaybackTime = targetTime
        playbackProgress = progress
    }
}

// MARK: - ViewModel

@MainActor
class MusicViewModel: ObservableObject {
    @Published var albums: [MusicAlbum] = []
    @Published var isLoading = false
    @Published var error: Error?
    @Published var showPermissionAlert = false
    
    private var colorCache: [String: [Color]] = [:]
    private let imageCache = ImageCacheManager.shared
    private let artworkLoadingQueue = DispatchQueue(label: "ArtworkLoading", qos: .userInitiated, attributes: .concurrent)
    private var loadingTasks: [String: Task<Void, Never>] = [:]
    private var failedArtworkLoads: Set<String> = []
    private var artworkLoadAttempts: [String: Int] = [:]
    
    // Concurrency management
    private let maxConcurrentTasks = 5
    private var activeTasks: Set<String> = []
    private let taskQueue = DispatchQueue(label: "TaskQueue", qos: .userInitiated)
    private let taskSemaphore = DispatchSemaphore(value: 5)
    
    func fetchAlbums() async {
        guard !isLoading else { return }
        isLoading = true
        
        // Request authorization for local music library
        await requestAuthorization()
    }
    
    private func requestAuthorization() async {
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { authStatus in
                continuation.resume(returning: authStatus)
            }
        }
        
        await MainActor.run {
            switch status {
            case .authorized:
                Task {
                    await self.loadAlbums()
                }
            case .denied, .restricted:
                self.error = NSError(domain: "Music", code: 403, userInfo: [
                    NSLocalizedDescriptionKey: "Music library access denied. Please enable access in Settings."
                ])
                self.showPermissionAlert = true
                self.isLoading = false
            case .notDetermined:
                self.error = NSError(domain: "Music", code: 401, userInfo: [
                    NSLocalizedDescriptionKey: "Music library access not determined."
                ])
                self.isLoading = false
            @unknown default:
                self.error = NSError(domain: "Music", code: 401, userInfo: [
                    NSLocalizedDescriptionKey: "Unknown authorization status."
                ])
                self.isLoading = false
            }
        }
    }
    
    private func loadAlbums() async {
        let query = MPMediaQuery.albums()
        let collections = query.collections ?? []
        
        // Quick initial load without artwork or colors
        let albums = collections.compactMap { collection -> MusicAlbum? in
            guard let representativeItem = collection.representativeItem else { return nil }
            
            let albumId = String(representativeItem.albumPersistentID)
            let title = representativeItem.albumTitle ?? "Unknown Album"
            let artist = representativeItem.albumArtist ?? "Unknown Artist"
            
            return MusicAlbum(
                id: albumId,
                title: title,
                artist: artist,
                artwork: nil, // Load artwork lazily
                colors: [Color.gray, Color.black], // Default colors
                songs: collection.items
            )
        }
        
        // Update UI immediately with basic album info
        await MainActor.run {
            self.albums = albums.sorted { $0.title < $1.title }
            self.isLoading = false
            
            // Handle empty library case
            if self.albums.isEmpty {
                self.error = NSError(domain: "Music", code: 404, userInfo: [
                    NSLocalizedDescriptionKey: "No albums found in your music library."
                ])
            }
        }
    }
    
    private func loadImage(from url: URL) async throws -> UIImage {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let image = UIImage(data: data) else {
            throw NSError(domain: "ImageError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
        }
        return image
    }
    
    func loadArtworkAndColors(for albumId: String, priority: TaskPriority = .userInitiated, retryCount: Int = 0, forceReload: Bool = false) async -> (UIImage?, [Color]) {
        // Cancel any existing loading task for this album
        loadingTasks[albumId]?.cancel()
        
        // Check if we already have cached data and not forcing reload
        if !forceReload, let cachedArtwork = imageCache.getImage(for: albumId),
           let cachedColors = colorCache[albumId] {
            return (cachedArtwork, cachedColors)
        }
        
        // Skip if this album has failed too many times, unless forcing reload
        if !forceReload, failedArtworkLoads.contains(albumId) {
            return (nil, [Color.gray, Color.black])
        }
        
        // Concurrency control: Check if we're already at the limit
        await withCheckedContinuation { continuation in
            self.taskQueue.async {
                self.taskSemaphore.wait()
                continuation.resume()
            }
        }
        
        // Track active tasks
        _ = await MainActor.run {
            self.activeTasks.insert(albumId)
        }
        
        // Track loading attempts
        artworkLoadAttempts[albumId] = (artworkLoadAttempts[albumId] ?? 0) + 1
        
        // Create a new loading task with retry mechanism
        let task = Task(priority: priority) { [weak self] in
            guard let self = self else { return (nil as UIImage?, [Color.gray, Color.black]) }
            let maxRetries = 3
            var currentRetry = retryCount
            
            defer {
                // Release semaphore and cleanup when task completes
                self.taskSemaphore.signal()
                Task { @MainActor in
                    self.activeTasks.remove(albumId)
                }
            }
            
            while currentRetry < maxRetries {
                await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        // Load artwork on background thread
                        let query = MPMediaQuery.albums()
                        guard let collection = query.collections?.first(where: {
                            String($0.representativeItem?.albumPersistentID ?? 0) == albumId
                        }),
                              let representativeItem = collection.representativeItem else {
                            print("[Error] Could not find collection for album ID: \(albumId)")
                            return false
                        }
                        
                        // Use single optimal size for performance
                        let optimalSize = CGSize(width: 200, height: 200)
                        let artwork = representativeItem.artwork?.image(at: optimalSize)
                        
                        if let artwork = artwork {
                            // Cache the artwork
                            await MainActor.run {
                                self.imageCache.setImage(artwork, for: albumId)
                            }
                            
                            // Extract colors on background thread
                            let colors = await self.extractColorsSync(from: artwork)
                            
                            await MainActor.run {
                                self.colorCache[albumId] = colors
                            }
                            
                            print("Successfully loaded artwork for album: \(representativeItem.albumTitle ?? "Unknown")")
                            return true
                        } else {
                            let attempts = await MainActor.run { self.artworkLoadAttempts[albumId] ?? 0 }
                            print("[Error] No artwork available for album: \(representativeItem.albumTitle ?? "Unknown") (Attempt \(attempts))")
                            return false
                        }
                    }
                }
                
                // Check if successful
                if imageCache.getImage(for: albumId) != nil {
                    break
                }
                
                currentRetry += 1
                if currentRetry < maxRetries {
                    print("[Retry] Artwork load for album ID \(albumId), attempt \(currentRetry + 1)")
                    // Brief delay before retry
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                } else {
                    // Mark as failed after all retries
                    _ = await MainActor.run {
                        self.failedArtworkLoads.insert(albumId)
                    }
                    print("[Failed] Artwork load for album ID \(albumId) after \(maxRetries) attempts")
                }
            }
            
            // Return the final result
            return (self.imageCache.getImage(for: albumId), self.colorCache[albumId] ?? [Color.gray, Color.black])
        }
        
        loadingTasks[albumId] = Task {
            _ = await task.value
        }
        let result = await task.value
        loadingTasks.removeValue(forKey: albumId)
        
        return result
    }
    
    func forceReloadArtwork(for albumId: String) async -> (UIImage?, [Color]) {
        // Remove from failed set and reset attempts
        failedArtworkLoads.remove(albumId)
        artworkLoadAttempts[albumId] = 0
        
        // Clear cached data
        imageCache.clearMemoryCache()
        colorCache.removeValue(forKey: albumId)
        
        // Force reload
        return await loadArtworkAndColors(for: albumId, priority: .high, forceReload: true)
    }
    
    private func extractColors(from image: UIImage?) async -> [Color] {
        return await extractColorsSync(from: image)
    }
    
    private func extractColorsSync(from image: UIImage?) async -> [Color] {
        guard let image = image else { return [Color.gray, Color.black] }
        let cacheKey = "\(image.size.width)x\(image.size.height)\(image.hashValue)"
        if let cached = colorCache[cacheKey] {
            return cached
        }
        
        if let vibrantColors = image.getColors() {
            let extracted = [
                Color(vibrantColors.background),
                Color(vibrantColors.primary),
                Color(vibrantColors.secondary),
                Color(vibrantColors.detail)
            ]
            colorCache[cacheKey] = extracted
            return extracted
        }
        
        return [Color.gray, Color.black]
    }
}

// MARK: - Main View

struct MusicPalettePlayer: View {
    @StateObject private var viewModel = MusicViewModel()
    @State private var selectedAlbum: MusicAlbum?
    @State private var focusedPetal: Int? = nil
    
    // Music player controls state
    @State private var isPlaying = false
    @State private var playbackProgress: CGFloat = 0.4
    @State private var isShuffle = false
    @State private var isRepeat = false
    @State private var currentlyPlayingAlbum: MusicAlbum?
    @State private var currentTrackIndex = 0
    
    // Track listing card state
    @State private var showTrackListing = false
    @State private var trackListingAlbum: MusicAlbum?
    
    // Audio player
    @StateObject private var audioPlayer = AudioPlayerManager()
    
    // Keep UI state in sync with player
    private func syncPlayerState() {
        isPlaying = audioPlayer.isPlaying
        playbackProgress = CGFloat(audioPlayer.playbackProgress)
    }
    
    // Music control functions
    private func playSelectedAlbum() {
        guard let album = selectedAlbum else { return }
        
        currentlyPlayingAlbum = album
        currentTrackIndex = 0
        isPlaying = true
        playbackProgress = 0.0
        
        // Play the entire album starting from the first track
        audioPlayer.playAlbum(album.songs, startingAt: 0)
        
        // Add haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    private func togglePlayPause() {
        if isPlaying {
            audioPlayer.pause()
            isPlaying = false
        } else {
            if currentlyPlayingAlbum?.id == selectedAlbum?.id {
                // Resume current track
                audioPlayer.resume()
                isPlaying = true
            } else {
                // Play selected album
                playSelectedAlbum()
            }
        }
        
        // Add haptic feedback
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    private func skipToNext() {
        guard let album = currentlyPlayingAlbum else {
            playSelectedAlbum()
            return
        }
        
        if isShuffle {
            // Random next track
            currentTrackIndex = Int.random(in: 0..<album.songs.count)
        } else {
            // Sequential next track
            currentTrackIndex += 1
            if currentTrackIndex >= album.songs.count {
                if isRepeat {
                    currentTrackIndex = 0
                } else {
                    isPlaying = false
                    return
                }
            }
        }
        
        let nextSong = album.songs[currentTrackIndex]
        audioPlayer.playTrack(nextSong)
        playbackProgress = 0.0
        
        // Add haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    private func skipToPrevious() {
        guard let album = currentlyPlayingAlbum else {
            playSelectedAlbum()
            return
        }
        
        if isShuffle {
            // Random previous track
            currentTrackIndex = Int.random(in: 0..<album.songs.count)
        } else {
            // Sequential previous track
            currentTrackIndex -= 1
            if currentTrackIndex < 0 {
                if isRepeat {
                    currentTrackIndex = album.songs.count - 1
                } else {
                    currentTrackIndex = 0
                }
            }
        }
        
        let prevSong = album.songs[currentTrackIndex]
        audioPlayer.playTrack(prevSong)
        playbackProgress = 0.0
        
        // Add haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    private func toggleShuffle() {
        isShuffle.toggle()
        // Add haptic feedback
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    private func toggleRepeat() {
        isRepeat.toggle()
        // Add haptic feedback
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    // Function to play a specific track from an album
    private func playTrack(_ track: MPMediaItem, fromAlbum album: MusicAlbum) {
        currentlyPlayingAlbum = album
        if let trackIndex = album.songs.firstIndex(of: track) {
            currentTrackIndex = trackIndex
        }
        
        audioPlayer.playTrack(track)
        isPlaying = true
        playbackProgress = 0.0
        
        // Close track listing
        showTrackListing = false
        
        // Add haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    // Function to show track listing for an album
    private func showTrackListingFor(_ album: MusicAlbum) {
        trackListingAlbum = album
        showTrackListing = true
        
        // Add haptic feedback
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    private func loadArtworkForAlbum(_ album: MusicAlbum, priority: TaskPriority = .userInitiated) async {
        // Skip if already loaded to avoid redundant work
        guard !album.hasLoadedArtwork || !album.hasLoadedColors else { return }
        
        // Load artwork and colors with specified priority
        let (artwork, colors) = await viewModel.loadArtworkAndColors(for: album.id, priority: priority, forceReload: false)
        
        // Update the album in the array with the loaded artwork
        if let index = viewModel.albums.firstIndex(where: { $0.id == album.id }) {
            // Create updated album with persistent artwork
            let updatedAlbum = MusicAlbum(
                id: album.id,
                title: album.title,
                artist: album.artist,
                artwork: artwork ?? album.artwork, // Keep existing artwork if new one fails
                colors: colors.isEmpty ? album.colors : colors,
                songs: album.songs
            )
            
            // Update in main array
            await MainActor.run {
                viewModel.albums[index] = updatedAlbum
                
                // Update selected album if it's the same one
                if selectedAlbum?.id == album.id {
                    selectedAlbum = updatedAlbum
                }
                
                // Update track listing album if it's the same one
                if trackListingAlbum?.id == album.id {
                    trackListingAlbum = updatedAlbum
                }
            }
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()
                if viewModel.albums.isEmpty {
                    if viewModel.isLoading {
                        ProgressView("Loading albums…")
                            .padding()
                    } else if let error = viewModel.error {
                        VStack {
                            Text("Error loading music")
                                .font(.headline)
                            Text(error.localizedDescription)
                                .font(.subheadline)
                            Button("Try Again") {
                                Task {
                                    await viewModel.fetchAlbums()
                                }
                            }
                            .padding(.top, 8)
                            
                            if viewModel.showPermissionAlert {
                                Button("Open Settings") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }
                        .foregroundColor(.white)
                        .padding()
                    } else {
                        Text("No albums found.")
                            .padding()
                    }
                } else {
                    FlowerSpinnerView(
                        albums: viewModel.albums,
                        selectedAlbum: $selectedAlbum,
                        focusedPetal: $focusedPetal,
                        loadArtworkForAlbum: loadArtworkForAlbum,
                        showTrackListingFor: showTrackListingFor
                    )
                    .frame(height: 400)
                    .padding(.vertical)
                    
                    if focusedPetal == nil, let album = selectedAlbum {
                        AlbumDetailView(album: album)
                            .padding(.horizontal)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .animation(.easeInOut(duration: 0.3), value: selectedAlbum?.id)
                    }
                }
                Spacer()
                ControlPanel(
                    isPlaying: $isPlaying,
                    playbackProgress: $playbackProgress,
                    isShuffle: $isShuffle,
                    isRepeat: $isRepeat,
                    skipToNext: skipToNext,
                    skipToPrevious: skipToPrevious,
                    toggleShuffle: toggleShuffle,
                    toggleRepeat: toggleRepeat,
                    togglePlayPause: togglePlayPause
                )
                .padding(.bottom, 40)
            }
        }
        .task {
            await viewModel.fetchAlbums()
            if let first = viewModel.albums.first {
                selectedAlbum = first
                // Load artwork and colors for the first album with high priority
                await loadArtworkForAlbum(first, priority: .high)
            }
        }
        .onReceive(audioPlayer.$isPlaying) { newValue in
            isPlaying = newValue
        }
        .onReceive(audioPlayer.$playbackProgress) { newValue in
            playbackProgress = CGFloat(newValue)
        }
        .overlay(
            // Track listing card overlay
            Group {
                if showTrackListing, let album = trackListingAlbum {
                    TrackListingCard(
                        album: album,
                        playTrack: playTrack,
                        onDismiss: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                showTrackListing = false
                            }
                        }
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.1).combined(with: .opacity),
                        removal: .scale(scale: 0.1).combined(with: .opacity)
                    ))
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: showTrackListing)
                    .zIndex(100)
                }
            }
        )
        .background(
            LinearGradient(
                gradient: Gradient(colors: selectedAlbum?.colors ?? [.purple, .black]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: selectedAlbum?.colors)
        )
    }
}

// MARK: - Flower Spinner

struct FlowerSpinnerView: View {
    let albums: [MusicAlbum]
    let radius: CGFloat = 140
    let petalSize: CGFloat = 90  // Increased size for bigger artwork
    let petalsInView = 15  // Number of petals visible at once to match original
    
    @Binding var selectedAlbum: MusicAlbum?
    @Binding var focusedPetal: Int?
    let loadArtworkForAlbum: (MusicAlbum, TaskPriority) async -> Void
    let showTrackListingFor: (MusicAlbum) -> Void
    
    @State private var currentOffset: Double = 0  // Current position in the album array
    @State private var dragVelocity: Double = 0
    @State private var lastDragValue: CGFloat = 0
    @State private var isDragging = false
    @State private var displayRotation: Double = 0
    // Focus is now external (@Binding)
    // @State private var focusedPetal: Int? = nil  // Remove local (duplicate)
    
    @State private var glowPulse = false
    @State private var shimmerPhase: CGFloat = 0
    @State private var tappedPetal: Int? = nil  // Track which petal was just tapped
    
    private let hapticImpact = UIImpactFeedbackGenerator(style: .medium)
    @State private var inertiaTask: Task<Void, Never>? = nil
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dynamic background glow based on selected album colors
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                (selectedAlbum?.colors.first ?? Color.purple).opacity(0.15),
                                Color.black.opacity(0.7)
                            ]),
                            center: .center,
                            startRadius: 0,
                            endRadius: radius + petalSize * 1.8
                        )
                    )
                    .frame(width: (radius + petalSize * 2) * 2, height: (radius + petalSize * 2) * 2)
                    .shadow(color: (selectedAlbum?.colors.first ?? Color.purple).opacity(0.3), radius: 30, x: 0, y: 20)
                    .blur(radius: 8)
                    .offset(y: 15)
                    .animation(.easeInOut(duration: 0.8), value: selectedAlbum?.colors)
                
                ZStack {
                    // Render visible petals based on current offset
                    ForEach(visiblePetalIndices, id: \.self) { virtualIndex in
                        let albumIndex = (Int(currentOffset) + virtualIndex) % albums.count
                        let album = albums[albumIndex]
                        let petalPosition = virtualIndex
                        
                        petalView(for: album, isFocused: focusedPetal == petalPosition, isTapped: tappedPetal == petalPosition)
                            .frame(width: petalSize, height: petalSize)
                            .offset(petalOffset(at: petalPosition))
                            .rotationEffect(.degrees(displayRotation))
                            .scaleEffect(focusedPetal == petalPosition ? 1.5 : (isSelectedPetal(virtualIndex) ? 1.2 : 0.9))
                            .shadow(
                                color: neonGlowColor(for: album).opacity(isSelectedPetal(virtualIndex) ? 0.8 : 0.4),
                                radius: isSelectedPetal(virtualIndex) ? 15 : 8,
                                x: 0,
                                y: isSelectedPetal(virtualIndex) ? 8 : 4
                            )
                            .overlay(
                                Circle()
                                    .stroke(
                                        neonGlowColor(for: album).opacity(isSelectedPetal(virtualIndex) ? (glowPulse ? 1.0 : 0.6) : 0.2),
                                        lineWidth: isSelectedPetal(virtualIndex) ? 3 : 1
                                    )
                            )
                            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: currentOffset)
                            .highPriorityGesture(
                                TapGesture()
                                    .onEnded {
                                        if focusedPetal == petalPosition {
                                            // Tap again to unfocus if already focused
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                focusedPetal = nil
                                            }
                                        } else {
                                            hapticImpact.impactOccurred()
                                            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                                focusedPetal = petalPosition
                                                snapToPosition(petalPosition)
                                                selectedAlbum = album
                                            }
                                            Task {
                                                await loadArtworkForAlbum(album, .high)
                                            }
                                        }
                                    }
                            )
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { _ in
                                        if focusedPetal == petalPosition {
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                focusedPetal = nil
                                            }
                                        }
                                    }
                            )
                            .onAppear {
                                if selectedAlbum?.id == album.id {
                                    glowPulse = true
                                }
                                // Load artwork with priority based on selection
                                Task {
                                    let priority: TaskPriority = selectedAlbum?.id == album.id ? .high : .userInitiated
                                    await loadArtworkForAlbum(album, priority)
                                }
                            }
                            .onDisappear {
                                glowPulse = false
                            }
                            .onTapGesture {
                                hapticImpact.impactOccurred()
                                // Focus this petal (shows expanded info), and update selection
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                    focusedPetal = petalPosition
                                    snapToPosition(petalPosition)
                                    selectedAlbum = album
                                }
                                // Update album colors as soon as tapped
                                Task {
                                    await loadArtworkForAlbum(album, .high)
                                }
                            }
                            .onLongPressGesture {
                                hapticImpact.impactOccurred()
                                
                                // Show track listing card on long press
                                showTrackListingFor(album)
                            }
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            inertiaTask?.cancel()
                            isDragging = true
                            let dragDelta = value.translation.width - lastDragValue
                            lastDragValue = value.translation.width
                            
                            // Convert drag to rotation through album array
                            let sensitivity: Double = 0.01
                            let deltaOffset = -Double(dragDelta) * sensitivity
                            currentOffset = fmod(currentOffset + deltaOffset + Double(albums.count), Double(albums.count))
                            
                            // Calculate velocity for inertia
                            dragVelocity = -Double(value.predictedEndTranslation.width - value.translation.width) * sensitivity
                            
                            updateDisplayRotation()
                            updateSelectedAlbum()
                        }
                        .onEnded { _ in
                            lastDragValue = 0
                            isDragging = false
                            startInertia()
                        }
                )
                
                // Background tap gesture to unfocus
                if focusedPetal != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                focusedPetal = nil
                            }
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear {
                currentOffset = 0
                displayRotation = 0
                updateSelectedAlbum()
                startContinuousRotation()
                
                // Start shimmer animation
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmerPhase = 1.0
                }
                
                // Preload artwork for initial visible petals with staggered loading
                Task {
                    await withTaskGroup(of: Void.self) { group in
                        for (priority, i) in visiblePetalIndices.enumerated() {
                            let albumIndex = i % albums.count
                            let album = albums[albumIndex]
                            
                            group.addTask {
                                // Load center petals first, then outer ones
                                let taskPriority: TaskPriority = priority < 3 ? .userInitiated : .background
                                await loadArtworkForAlbum(album, taskPriority)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 2 * (radius + petalSize))
    }

    // Computed properties for the circular arrangement
    var visiblePetalIndices: Range<Int> {
        return 0..<petalsInView
    }
    
    var anglePerPetal: Double {
        360.0 / Double(petalsInView)
    }
    
    func petalOffset(at index: Int) -> CGSize {
        let angle = Double(index) * anglePerPetal * Double.pi / 180
        let x = radius * CGFloat(cos(angle))
        let y = radius * CGFloat(sin(angle))
        return CGSize(width: x, height: y)
    }
    
    func isSelectedPetal(_ petalIndex: Int) -> Bool {
        // The "selected" petal is always the top one (index 0)
        return petalIndex == 0
    }
    
    func neonGlowColor(for album: MusicAlbum) -> Color {
        if selectedAlbum?.id == album.id {
            // Use the album's primary color for glow if available
            return album.hasLoadedColors && album.colors.count > 1 ? album.colors[1] : Color.purple
        } else {
            return album.hasLoadedColors && !album.colors.isEmpty ? album.colors[0].opacity(0.5) : selectedAlbum?.colors.first?.opacity(0.5) ?? Color.purple.opacity(0.5)
        }
    }
    
    func updateDisplayRotation() {
        // Smooth rotation animation based on current position
        let rotationPerAlbum = anglePerPetal
        displayRotation = currentOffset * rotationPerAlbum
    }
    
    func updateSelectedAlbum() {
        guard !albums.isEmpty else { return }
        let selectedIndex = Int(currentOffset.rounded()) % albums.count
        let selectedAlbumCandidate = albums[selectedIndex]
        
        if selectedAlbum?.id != selectedAlbumCandidate.id {
            selectedAlbum = selectedAlbumCandidate
            hapticImpact.impactOccurred()
            
            // Load artwork for the new selection and surrounding albums with proper prioritization
            Task {
                // Load selected album with high priority
                await loadArtworkForAlbum(selectedAlbumCandidate, .high)
                
                // Preload artwork for visible albums with lower priority
                await withTaskGroup(of: Void.self) { group in
                    for i in visiblePetalIndices {
                        let preloadIndex = (Int(currentOffset) + i) % albums.count
                        let preloadAlbum = albums[preloadIndex]
                        
                        group.addTask {
                            await loadArtworkForAlbum(preloadAlbum, .background)
                        }
                    }
                }
            }
        }
    }
    
    func startContinuousRotation() {
        // Only gentle idle rotation when not interacting
        inertiaTask?.cancel()
        inertiaTask = Task {
            while !Task.isCancelled {
                if !isDragging && abs(dragVelocity) < 0.01 {
                    // Very slow idle rotation
                    currentOffset = fmod(currentOffset + 0.002, Double(albums.count))
                    updateDisplayRotation()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000 / 60)
            }
        }
    }
    
    func startInertia() {
        inertiaTask?.cancel()
        inertiaTask = Task {
            var velocity = dragVelocity
            while abs(velocity) > 0.001 && !Task.isCancelled {
                currentOffset = fmod(currentOffset + velocity + Double(albums.count), Double(albums.count))
                updateDisplayRotation()
                updateSelectedAlbum()
                velocity *= 0.94  // Deceleration
                try? await Task.sleep(nanoseconds: 1_000_000_000 / 60)
            }
            
            // Snap to nearest album
            await MainActor.run {
                snapToNearestAlbum()
            }
            startContinuousRotation()
        }
    }
    
    func snapToNearestAlbum() {
        let targetOffset = currentOffset.rounded()
        withAnimation(.interactiveSpring(response: 0.6, dampingFraction: 0.8)) {
            currentOffset = targetOffset
            updateDisplayRotation()
            updateSelectedAlbum()
        }
    }
    
    func snapToPosition(_ position: Int) {
        let targetOffset = Double(Int(currentOffset) + position)
        withAnimation(.interactiveSpring(response: 0.5, dampingFraction: 0.7)) {
            currentOffset = fmod(targetOffset, Double(albums.count))
            updateDisplayRotation()
            updateSelectedAlbum()
        }
    }
    
    @ViewBuilder
    func petalView(for album: MusicAlbum, isFocused: Bool = false, isTapped: Bool = false) -> some View {
    ZStack {
        // Focus overlay for expanded detail view
        if isFocused {
            VStack(spacing: 8) {
                // Enlarged album artwork
                if let artwork = album.artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: petalSize * 1.3, height: petalSize * 1.3)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.5), lineWidth: 3)
                        )
                }
                
                // Album details
                VStack(spacing: 4) {
                    Text(album.title)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    
                    Text(album.artist)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                    
                    Text("\(album.songs.count) songs")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.7))
                        .blur(radius: 2)
                )
            }
            .frame(width: petalSize * 1.8, height: petalSize * 2.2)
            .zIndex(1)
        }
        // Background color petal based on album colors
        if album.hasLoadedColors && !album.colors.isEmpty {
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            album.colors.first ?? .gray,
                            album.colors.count > 1 ? album.colors[1] : .black
                        ]),
                        center: .center,
                        startRadius: 10,
                        endRadius: 45
                    )
                )
                .frame(width: petalSize, height: petalSize)
        } else {
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [.gray, .black]),
                        center: .center,
                        startRadius: 10,
                        endRadius: 45
                    )
                )
                .frame(width: petalSize, height: petalSize)
        }
        
        // Album artwork overlay (larger and more visible)
        if let artwork = album.artwork {
            Image(uiImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: petalSize * 0.8, height: petalSize * 0.8)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.6), lineWidth: 2)
                )
        } else {
            // Loading shimmer effect for albums without artwork
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: petalSize * 0.8, height: petalSize * 0.8)
                
                // Shimmer overlay
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.clear,
                                Color.white.opacity(0.6),
                                Color.clear
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: petalSize * 0.8, height: petalSize * 0.8)
                    .mask(
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.clear,
                                        Color.white,
                                        Color.clear
                                    ]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .rotationEffect(.degrees(45))
                            .offset(x: (shimmerPhase - 0.5) * petalSize * 1.5)
                    )
                
                // Music note icon
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }
    .shadow(color: neonGlowColor(for: album).opacity(0.6), radius: 12, x: 0, y: 6)
    .overlay(
        // Tap shimmer effect
        Circle()
            .stroke(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(isTapped ? 1.0 : 0),
                        Color.white.opacity(0)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 4
            )
            .blur(radius: isTapped ? 8 : 0)
            .scaleEffect(isTapped ? 1.3 : 1.0)
            .animation(
                isTapped ?
                Animation.easeOut(duration: 0.6) :
                Animation.easeIn(duration: 0.1),
                value: isTapped
            )
    )
}
}

// MARK: - Album Detail View

struct AlbumDetailView: View {
    let album: MusicAlbum
    
    var body: some View {
        VStack(spacing: 8) {
            Text(album.title)
                .font(.title2)
                .bold()
                .foregroundColor(.white)
                .shadow(radius: 2)
                .multilineTextAlignment(.center)
            
            Text(album.artist)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
                .shadow(radius: 1)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.25))
                .blur(radius: 10)
        )
    }
}

// MARK: - Track Listing Card

struct TrackListingCard: View {
    let album: MusicAlbum
    let playTrack: (MPMediaItem, MusicAlbum) -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Header with album info and close button
                HStack {
                    // Album artwork
                    if let artwork = album.artwork {
                        Image(uiImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 60, height: 60)
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.title2)
                                    .foregroundColor(.white.opacity(0.7))
                            )
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.title)
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .lineLimit(2)
                        
                        Text(album.artist)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                        
                        Text("\(album.songs.count) tracks")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    Spacer()
                    
                    // Close button
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.8))
                            .background(Color.black.opacity(0.3))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: album.hasLoadedColors && album.colors.count > 1 ? [album.colors[0], album.colors[1]] : [Color.gray, Color.black]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                
                // Track list
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(album.songs.enumerated()), id: \.element.persistentID) { index, track in
                            TrackRow(
                                track: track,
                                trackNumber: index + 1,
                                onTap: {
                                    playTrack(track, album)
                                }
                            )
                            
                            if index < album.songs.count - 1 {
                                Divider()
                                    .background(Color.white.opacity(0.1))
                                    .padding(.horizontal, 20)
                            }
                        }
                    }
                }
                .background(Color.black.opacity(0.8))
            }
            .frame(width: min(geometry.size.width * 0.85, 350), height: min(geometry.size.height * 0.7, 500))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .background(
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }
        )
    }
}

struct TrackRow: View {
    let track: MPMediaItem
    let trackNumber: Int
    let onTap: () -> Void
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Track number
                Text("\(trackNumber)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 24, alignment: .trailing)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title ?? "Unknown Track")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    if let artist = track.artist {
                        Text(artist)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                // Duration
                Text(formatDuration(track.playbackDuration))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            Color.white.opacity(0.05)
                .opacity(0) // Start transparent
        )
        .onHover { isHovered in
            // Add hover effect if needed
        }
    }
}

// MARK: - Controls

struct ControlPanel: View {
    @Binding var isPlaying: Bool
    @Binding var playbackProgress: CGFloat
    @Binding var isShuffle: Bool
    @Binding var isRepeat: Bool
    var skipToNext: () -> Void
    var skipToPrevious: () -> Void
    var toggleShuffle: () -> Void
    var toggleRepeat: () -> Void
    var togglePlayPause: () -> Void
    
    var body: some View {
        VStack(spacing: 25) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .foregroundColor(.white.opacity(0.2))
                    
                    Capsule()
                        .foregroundColor(.white)
                        .frame(width: geometry.size.width * playbackProgress)
                        .shadow(color: .white.opacity(0.8), radius: 3)
                }
            }
            .frame(height: 6)
            .padding(.horizontal, 30)
            
            HStack(spacing: 20) {
                Button(action: toggleShuffle) {
                    Image(systemName: "shuffle")
                        .font(.title3)
                        .foregroundColor(isShuffle ? .blue : .white)
                        .frame(width: 35, height: 35)
                }
                
                Button(action: skipToPrevious) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                        .frame(width: 40, height: 40)
                }
                
                Button(action: togglePlayPause) {
                    ZStack {
                        Circle()
                            .frame(width: 80, height: 80)
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                        
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundColor(.black)
                    }
                }
                
                Button(action: skipToNext) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                        .frame(width: 40, height: 40)
                }
                
                Button(action: toggleRepeat) {
                    Image(systemName: "repeat")
                        .font(.title3)
                        .foregroundColor(isRepeat ? .green : .white)
                        .frame(width: 35, height: 35)
                }
            }
            .foregroundColor(.white)
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .padding(.horizontal, 40)
    }
}

// MARK: - Preview

struct MusicPalettePlayer_Previews: PreviewProvider {
    static var previews: some View {
        MusicPalettePlayer()
    }
}

@main
struct Fan_ArtApp: App {
    var body: some Scene {
        WindowGroup {
            MusicPalettePlayer()
        }
    }
}
