// MARK: - Main App Structure
// IMPORTANT: Add to Info.plist:
// Key: NSPhotoLibraryUsageDescription
// Value: "Photo Swiper needs access to your photos to help you organize and delete unwanted images."
import SwiftUI
import Photos
import RealmSwift

@main
struct PhotoSwiperApp: SwiftUI.App {
    @StateObject private var photoManager = PhotoManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(photoManager)
                .onAppear {
                    photoManager.requestPhotoPermission()
                }
        }
    }
}

// MARK: - Photo Manager
class PhotoManager: ObservableObject {
    @Published var photos: [PhotoAsset] = []
    @Published var markedForDeletion: [PhotoAsset] = []
    @Published var likedPhotoIDs: Set<String> = []
    @Published var currentIndex: Int = 0
    @Published var hasPermission: Bool = false
    
    private let likedPhotosLocalStorageKey = "PhotoSwiper-LocalLikedPhoto"
    
    // Initializer to load liked photos from UserDefaults
    init() {
        if let storedLikedIDs = UserDefaults.standard.stringArray(forKey: likedPhotosLocalStorageKey) {
            self.likedPhotoIDs = Set(storedLikedIDs)
        }
        
        // Optional: Perform Realm migrations if needed
        let config = Realm.Configuration(
            schemaVersion: 1, // Increment if you change your Realm schema
            migrationBlock: { migration, oldSchemaVersion in
            })
        Realm.Configuration.defaultConfiguration = config
    }
    
    enum SortOrder {
        case oldToNew
        case random
        case album(String)
    }
    
    func requestPhotoPermission() {
        PHPhotoLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                self.hasPermission = status == .authorized
            }
        }
    }
    
    func loadPhotos(sortOrder: SortOrder) {
        guard hasPermission else { return }
        
        let fetchOptions = PHFetchOptions()
        
        switch sortOrder {
        case .oldToNew:
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        case .random:
            // Random sorting will be handled after fetch
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        case .album(let albumTitle):
            // Will implement album fetching logic
            break
        }
        
        // Fetch only photos, not videos or other media types
        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        
        // Create an array with the actual photos from PhotoAsset
        var allPhotos: [PhotoAsset] = []
        fetchResult.enumerateObjects { asset, index, stop in
            allPhotos.append(PhotoAsset(asset: asset))
        }
        
        // Shuffle if needed
        if case .random = sortOrder {
            allPhotos.shuffle()
        }
        
        // Load likedIDs from Realm *inside* loadPhotos()
        var likedIDs: Set<String> = []
        do {
            let realm = try Realm()
            let likedObjects = realm.objects(LikedPhotoObject.self)
            likedIDs = Set(likedObjects.map { $0.id })  // Get fresh IDs from Realm!
        } catch {
            print("Error loading liked photos from Realm: \(error)")
        }
        
        allPhotos = allPhotos.filter { !likedIDs.contains($0.id) }
        
        DispatchQueue.main.async {
            self.photos = allPhotos
            self.currentIndex = 0
            self.markedForDeletion = []
        }
    }
    
    func markCurrentPhotoForDeletion() {
        guard currentIndex < photos.count else {
            return
        }
        
        let photo = photos[currentIndex]
        if !markedForDeletion.contains(where: { $0.id == photo.id }) {
            markedForDeletion.append(photo)
        }
        
        moveToNextPhoto()
    }
    
    func markCurrentPhotoAsLiked() {
        guard currentIndex < photos.count else {
            return
        }
        
        let photo = photos[currentIndex]
        do {
            let realm = try Realm()
            try realm.write {
                // Check if it's already in Realm to prevent duplicates if primaryKey was not set
                // With primaryKey, 'add' will automatically update if object exists.
                realm.add(LikedPhotoObject(id: photo.id), update: .modified)
            }
            
            // if a liked photo should no longer be in those categories.
            if let index = markedForDeletion.firstIndex(where: { $0.id == photo.id }) {
                markedForDeletion.remove(at: index)
            }
            
            moveToNextPhoto()
            
        } catch {
            print("Error saving liked photo to Realm: \(error)")
        }
    }
    
    func moveToNextPhoto() {
        if currentIndex < photos.count - 1 {
            currentIndex += 1
        }
    }
    
    func moveToPreviousPhoto() {
        if currentIndex > 0 {
            currentIndex -= 1
            print(photos[currentIndex].id)
        }
    }
    
    func confirmDeletion(completion: @escaping (Bool) -> Void) {
        guard !markedForDeletion.isEmpty else {
            completion(true)
            return
        }
        
        // Create array of PHAssets to delete
        let assetsToDelete = markedForDeletion.compactMap { $0.asset } as NSArray
        
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assetsToDelete)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    self.markedForDeletion = []
                }
                completion(success)
            }
        }
        
    }
}

// MARK: - Photo Asset Model
import Photos // Make sure to import Photos for PHAsset

struct PhotoAsset: Identifiable, Equatable {
    // The 'id' property should be the PHAsset's localIdentifier (a String)
    // This provides a unique and persistent identifier for the photo in the library.
    let id: String
    
    let asset: PHAsset
    
    // This initializer is crucial. It ensures that when a PhotoAsset is created
    // from a PHAsset, its 'id' property is correctly set to the PHAsset's
    // unique localIdentifier.
    init(asset: PHAsset) {
        self.asset = asset
        self.id = asset.localIdentifier // <-- This is where you get the "real image ID"
    }
    
    // The Equatable conformance method remains the same,
    // as it now correctly compares based on the persistent `id` (localIdentifier).
    static func == (lhs: PhotoAsset, rhs: PhotoAsset) -> Bool {
        return lhs.id == rhs.id
    }
    
    // Gets full image
    var fullImage: UIImage? {
        get async {
            let manager = PHImageManager.default()
            let option = PHImageRequestOptions()
            option.isSynchronous = true
            option.deliveryMode = .highQualityFormat
            option.resizeMode = .exact
            option.isNetworkAccessAllowed = true // Crucial for iCloud-only assets
            
            var image: UIImage?
            let _ = await withCheckedContinuation { continuation in
                manager.requestImage(for: asset,
                                     targetSize: PHImageManagerMaximumSize,
                                     contentMode: .aspectFit,
                                     options: option) { result, _ in
                    image = result
                    continuation.resume()
                }
            }
            
            return image
        }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @EnvironmentObject private var photoManager: PhotoManager
    
    var body: some View {
        NavigationView {
            if photoManager.hasPermission {
                HomeView()
            } else {
                PermissionView()
            }
        }
    }
}

// MARK: - Permission View
// TODO - CHECK THIS
struct PermissionView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo")
                .font(.system(size: 80))
                .foregroundColor(.blue)
            
            Text("Photo Access Required")
                .font(.title)
                .fontWeight(.bold)
            
            Text("This app needs access to your photo library to help you organize and delete photos.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button("Open Settings") {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .padding()
    }
}

// MARK: - Home View with Three Options (Buttons)
struct HomeView: View {
    @EnvironmentObject private var photoManager: PhotoManager
    @State private var selectedAlbum: String?
    @State private var showingAlbumPicker = false
    @State private var navigateToPhotoSwipe = false
    @State private var showSettingsMenu = false
    @State private var selection = true
    
    func restoreLikedPhotos() {
        do {
            let realm = try Realm()
            try realm.write {
                let allLikedPhotos = realm.objects(LikedPhotoObject.self)
                realm.delete(allLikedPhotos)
            }
        } catch {
            print("Error restoring all liked photos from Realm: \(error)")
        }
    }
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Photo Swiper")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Choose how to view your photos")
                .font(.subheadline)
                .foregroundColor(.gray)
            
            VStack(spacing: 15) {
                Button(action: {
                    photoManager.loadPhotos(sortOrder: .oldToNew)
                    navigateToPhotoSwipe = true
                }) {
                    OptionButton(title: "Old to New", systemImage: "arrow.up.arrow.down")
                }
                
                Button(action: {
                    photoManager.loadPhotos(sortOrder: .random)
                    navigateToPhotoSwipe = true
                }) {
                    OptionButton(title: "Random", systemImage: "shuffle")
                }
                
                /*Button(action: {
                 showingAlbumPicker = true
                 }) {
                 OptionButton(title: "Select Album", systemImage: "folder")
                 }
                 .sheet(isPresented: $showingAlbumPicker) {
                 // Album picker view would go here
                 Text("Album Picker")
                 .font(.title)
                 .padding()
                 }*/
            }
            .padding(.horizontal)
        }
        .padding()
        .background(
            NavigationLink(
                destination: PhotoSwipeView(),
                isActive: $navigateToPhotoSwipe,
                label: { EmptyView() }
            )
        )
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showSettingsMenu = true
                }) {
                    Image(systemName: "gearshape.fill") // Settings icon
                }
            }
        }
        .confirmationDialog("Select a color", isPresented: $showSettingsMenu,) {
            Button("Restore liked photos") {
                restoreLikedPhotos();
            }
        }
    }
}

// MARK: - Button
struct OptionButton: View {
    let title: String
    let systemImage: String
    
    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .font(.title2)
            
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .foregroundColor(.gray)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .foregroundColor(.primary) // Ensures text is visible
    }
}

// MARK: - Photo Swipe View
struct PhotoSwipeView: View {
    @EnvironmentObject private var photoManager: PhotoManager
    @State private var offset: CGSize = .zero
    @State private var showBackConfirmation = false
    @State private var showFinishConfirmation = false
    @GestureState private var isDragging = false
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            if photoManager.photos.isEmpty {
                Text("No photos found")
                    .font(.title)
                    .foregroundColor(.gray)
            } else if photoManager.currentIndex >= photoManager.photos.count {
                VStack {
                    Text("All photos reviewed!")
                        .font(.title)
                    
                    Text("You've marked \(photoManager.markedForDeletion.count) photos for deletion")
                        .padding()
                    
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .disabled(photoManager.markedForDeletion.isEmpty)
                }
            } else {
                // Current photo card
                PhotoCard(photo: photoManager.photos[photoManager.currentIndex])
                    .id(photoManager.photos[photoManager.currentIndex].id) // Force view refresh when photo changes
                    .offset(x: offset.width, y: 0)
                    .rotationEffect(.degrees(Double(offset.width / 20)))
                    .gesture(
                        DragGesture()
                            .updating($isDragging) { value, state, _ in
                                state = true
                            }
                            .onChanged { gesture in
                                offset = gesture.translation
                            }
                            .onEnded { gesture in
                                withAnimation {
                                    if offset.width < -100 {
                                        //Swipe left - delete
                                        photoManager.markCurrentPhotoForDeletion() // Mark to delete the picture
                                    } else if offset.width > 100 {
                                        // Swipe right - keep
                                        photoManager.markCurrentPhotoAsLiked() // Skip the picture
                                    }
                                    offset = .zero // Reset offset for the new card
                                }
                            }
                    )
                
                // Swipe instructions
                VStack {
                    Spacer()
                    
                    HStack(spacing: 20) {
                        Button(action: {
                            // Simualate swipe animation
                            withAnimation(.easeOut(duration: 0.3)) { // Short, quick animation
                                offset = CGSize(width: -500, height: 0) // Swipe left
                            }
                            
                            //Force swipe event with a delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                withAnimation {
                                    photoManager.markCurrentPhotoForDeletion() // Mark to delete the picture
                                    offset = .zero // Reset offset for the new card
                                }
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill") // SFSymbol for trash/reject
                                .font(.system(size: 55))
                                .foregroundColor(.red)
                                .padding(0)
                                .background(Color.white)
                                .cornerRadius(10)
                                .clipShape(Circle())
                        }
                        
                        if(false && photoManager.currentIndex > 0){
                            Button(action: {
                                photoManager.moveToPreviousPhoto()
                            }) {
                                Image(systemName: "arrow.uturn.backward.circle.fill") // SFSymbol for rewind
                                    .font(.system(size: 55))
                                    .foregroundColor(.orange)
                                    .padding(0)
                                    .background(Color.white)
                                    .cornerRadius(10)
                                    .clipShape(Circle())
                            }
                        }
                        
                        Button(action: {
                            // Simualate swipe animation
                            withAnimation(.easeOut(duration: 0.3)) { // Short, quick animation
                                offset = CGSize(width: 500, height: 0) // Swipe right
                            }
                            
                            //Force swipe event with a delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                withAnimation {
                                    photoManager.markCurrentPhotoAsLiked() // Mark to delete the picture
                                    offset = .zero // Reset offset for the new card
                                }
                            }
                        }) {
                            Image(systemName: "heart.circle.fill") // SFSymbol for heart/like
                                .font(.system(size: 55))
                                .foregroundColor(.green)
                                .padding(0)
                                .background(Color.white)
                                .cornerRadius(10)
                                .clipShape(Circle())
                        }
                    }.padding(.vertical, 20)
                }
            }
        }
        .navigationTitle("Photo Review")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)  // hide the default Back button
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    if photoManager.markedForDeletion.count > 0 {
                        showBackConfirmation = true
                    } else {
                        presentationMode.wrappedValue.dismiss()
                    }
                }) {
                    Image(systemName: "chevron.backward") // The back chevron icon
                    Text("Back")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if photoManager.markedForDeletion.count > 0 {
                    Button(action: {
                        if photoManager.markedForDeletion.count > 0 {
                            photoManager.confirmDeletion { success in
                                if success {
                                    presentationMode.wrappedValue.dismiss()
                                }
                            }
                        } else {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }) {
                        Text("Finish (\(photoManager.markedForDeletion.count))")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .confirmationDialog("Cancel progress", isPresented: $showBackConfirmation, titleVisibility: .visible) {
            Button("Yes", role: .destructive) {
                presentationMode.wrappedValue.dismiss()
            }
            Button("No", role: .cancel) {
                return
            }
        } message: {
            Text("You already had \(photoManager.markedForDeletion.count) photo(s) selected.\nAre you sure you want to lose your progress?")
        }
    }
}

struct PhotoCard: View {
    let photo: PhotoAsset
    @State private var image: UIImage?
    @State private var loadingError = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemGray6))
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(20)
            } else if loadingError {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text("Could not load the image.\nPlease try again with internet connection")
                        .padding(.top, 8)
                }
            } else {
                ProgressView()
                    .scaleEffect(1.5)
            }
        }
        .frame(width: UIScreen.main.bounds.width - 40, height: UIScreen.main.bounds.height * 0.6)
        .shadow(radius: 5)
        .onAppear {
            // Reset image state when the card appears
            image = nil
            loadingError = false
            
            // Load the image
            Task {
                if let img = await photo.fullImage {
                    image = img
                } else {
                    loadingError = true
                    print("Can't load image: ", photo.id)
                }
            }
        }
    }
}

/*
struct PhotoSwipeView_Previews: PreviewProvider {
    static var previews: some View {
        // Create a mock PhotoManager for the preview
        let mockPhotoManager = PhotoManager()

        // Provide some dummy data for 'photos' for the preview
        // Note: You can't easily create a mock PHAsset.
        // For previews, you might represent PhotoAsset without a real PHAsset
        // or use placeholder images. Here, we'll make a simple mock.
        // For a full app, you'd probably have a way to generate dummy PhotoAsset.

        return NavigationView { // Wrap in NavigationView if your view expects one
            PhotoSwipeView()
                .environmentObject(mockPhotoManager)
        }
    }
}*/
