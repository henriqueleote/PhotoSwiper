// MARK: - Main App Structure
// IMPORTANT: Add to Info.plist:
// Key: NSPhotoLibraryUsageDescription
// Value: "Photo Swiper needs access to your photos to help you organize and delete unwanted images."
import SwiftUI
import Photos

@main
struct PhotoSwiperApp: App {
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
    @Published var currentIndex: Int = 0
    @Published var hasPermission: Bool = false
    
    enum SortOrder {
        case oldToNew
        case random
        case album(String)
    }
    
    func requestPhotoPermission() {
        PHPhotoLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                self.hasPermission = status == .authorized
                if self.hasPermission {
                    print("Photo access granted")
                }
            }
        }
    }
    
    func loadPhotos(sortOrder: SortOrder) {
        guard hasPermission else { return }
        print("Loading photos with sort order: \(sortOrder)")
        
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
        print("Found \(fetchResult.count) total photos")
        
        var newPhotos: [PhotoAsset] = []
        fetchResult.enumerateObjects { asset, index, stop in
            newPhotos.append(PhotoAsset(asset: asset))
        }
        
        if case .random = sortOrder {
            newPhotos.shuffle()
        }
        
        DispatchQueue.main.async {
            self.photos = newPhotos
            self.currentIndex = 0
            self.markedForDeletion = []
            print("Loaded \(newPhotos.count) photos successfully")
        }
    }
    
    func markCurrentPhotoForDeletion() {
        guard currentIndex < photos.count else {
            print("Error: Current index out of bounds")
            return
        }
        
        let photo = photos[currentIndex]
        if !markedForDeletion.contains(where: { $0.id == photo.id }) {
            markedForDeletion.append(photo)
            print("Marked photo at index \(currentIndex) for deletion. Total: \(markedForDeletion.count)")
        }
        
        moveToNextPhoto()
    }
    
    func moveToNextPhoto() {
        if currentIndex < photos.count - 1 {
            print("Moving from photo \(currentIndex) to \(currentIndex + 1)")
            currentIndex += 1
        } else {
            print("Reached end of photos at index \(currentIndex)")
        }
    }
    
    func confirmDeletion(completion: @escaping (Bool) -> Void) {
        guard !markedForDeletion.isEmpty else {
            print("No photos marked for deletion")
            completion(true)
            return
        }
        
        // Create array of PHAssets to delete
        let assetsToDelete = markedForDeletion.compactMap { $0.asset } as NSArray
        print("Attempting to delete \(assetsToDelete.count) photos")
        
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assetsToDelete)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    print("Successfully deleted photos")
                    self.markedForDeletion = []
                } else if let error = error {
                    print("Error deleting photos: \(error.localizedDescription)")
                }
                completion(success)
            }
        }
    }
}

// MARK: - Photo Asset Model
struct PhotoAsset: Identifiable, Equatable {
    let id = UUID()
    let asset: PHAsset
    
    static func == (lhs: PhotoAsset, rhs: PhotoAsset) -> Bool {
        return lhs.id == rhs.id
    }
    
    var thumbnailImage: UIImage? {
        get async {
            let manager = PHImageManager.default()
            let option = PHImageRequestOptions()
            option.isSynchronous = true
            
            var thumbnail: UIImage?
            let _ = await withCheckedContinuation { continuation in
                manager.requestImage(for: asset,
                                     targetSize: CGSize(width: 200, height: 200),
                                     contentMode: .aspectFit,
                                     options: option) { image, _ in
                    thumbnail = image
                    continuation.resume()
                }
            }
            return thumbnail
        }
    }
    
    var fullImage: UIImage? {
        get async {
            let manager = PHImageManager.default()
            let option = PHImageRequestOptions()
            option.isSynchronous = true
            option.deliveryMode = .highQualityFormat
            option.resizeMode = .exact
            
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

// MARK: - Home View with Three Options
struct HomeView: View {
    @EnvironmentObject private var photoManager: PhotoManager
    @State private var selectedAlbum: String?
    @State private var showingAlbumPicker = false
    @State private var navigateToPhotoSwipe = false
    
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
                
                Button(action: {
                    showingAlbumPicker = true
                }) {
                    OptionButton(title: "Select Album", systemImage: "folder")
                }
                .sheet(isPresented: $showingAlbumPicker) {
                    // Album picker view would go here
                    Text("Album Picker")
                        .font(.title)
                        .padding()
                }
            }
            .padding(.horizontal)
        }
        .padding()
        .navigationBarHidden(true)
        .background(
            NavigationLink(
                destination: PhotoSwipeView(),
                isActive: $navigateToPhotoSwipe,
                label: { EmptyView() }
            )
        )
    }
}

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
    @State private var currentPhotoID = UUID() // Track the current photo identity
    
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
                PhotoCard(photo: photoManager.photos[photoManager.currentIndex], photoID: currentPhotoID)
                    .id(currentPhotoID) // Force view refresh when photo changes
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
                                        currentPhotoID = UUID() // Generate new ID to force view refresh
                                    } else if offset.width > 100 {
                                        // Swipe right - keep
                                        photoManager.moveToNextPhoto() // Skip the picture
                                        currentPhotoID = UUID() // Generate new ID to force view refresh
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
                            print("Trash tapped!")
                            // Simualate swipe animation
                            withAnimation(.easeOut(duration: 0.3)) { // Short, quick animation
                                offset = CGSize(width: -500, height: 0) // Swipe left
                            }
                            
                            //Force swipe event with a delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                withAnimation {
                                    photoManager.markCurrentPhotoForDeletion() // Mark to delete the picture
                                    currentPhotoID = UUID() // Generate new ID to force view refresh
                                    offset = .zero // Reset offset for the new card
                                }
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill") // SFSymbol for trash/reject
                                .font(.largeTitle)
                                .foregroundColor(.red)
                                .padding(10)
                                .background(Color.white)
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }
                        
                        Button(action: {
                            // Action for rewind button
                            print("Rewind tapped!")
                        }) {
                            Image(systemName: "arrow.uturn.backward.circle.fill") // SFSymbol for rewind
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                                .padding(10)
                                .background(Color.white)
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }
                        
                        Button(action: {
                            print("Heart tapped!")
                            // Simualate swipe animation
                            withAnimation(.easeOut(duration: 0.3)) { // Short, quick animation
                                offset = CGSize(width: 500, height: 0) // Swipe right
                            }
                            
                            //Force swipe event with a delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                withAnimation {
                                    photoManager.moveToNextPhoto() // Skip the picture
                                    currentPhotoID = UUID() // Generate new ID to force view refresh
                                    offset = .zero // Reset offset for the new card
                                }
                            }
                        }) {
                            Image(systemName: "heart.circle.fill") // SFSymbol for heart/like
                                .font(.largeTitle)
                                .foregroundColor(.green)
                                .padding(10)
                                .background(Color.white)
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }
                    }
                    .padding() // Add some padding around the entire stack
                    .padding(.horizontal, 50)
                    .padding(.bottom, 30)
                }
            }
        }
        .navigationTitle("Photo Review")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true) // HIDES THE DEFAULT BACK BUTTON
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
                Button(action: {
                    if photoManager.markedForDeletion.count > 0 {
                        showFinishConfirmation = true
                    } else {
                        presentationMode.wrappedValue.dismiss()
                    }
                }) {
                    Text("Finish (\(photoManager.markedForDeletion.count))")
                        .foregroundColor(photoManager.markedForDeletion.count > 0 ? .red : .blue)
                }
            }
        }
        .alert(isPresented: $showBackConfirmation) {
            print(showBackConfirmation)
            print("--- Alert modifier for Back Confirmation is being evaluated ---")
            return Alert(
                title: Text("Go back"),
                message: Text("You already had \(photoManager.markedForDeletion.count) photos selected. Are you sure you want to go back?"),
                primaryButton: .destructive(Text("Yes")) {
                    presentationMode.wrappedValue.dismiss()
                },
                secondaryButton: .cancel()
            )
        }
        .alert(isPresented: $showFinishConfirmation) {
            print("--- Alert modifier for FINISH Confirmation is being evaluated ---")
            return Alert(
                title: Text("Confirm deletion"),
                message: Text("Are you sure you want to delete \(photoManager.markedForDeletion.count) photos? This action cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    photoManager.confirmDeletion { success in
                        if success {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .onAppear {
            // Generate new ID to ensure fresh view when screen appears
            currentPhotoID = UUID()
        }
    }
}

struct PhotoCard: View {
    let photo: PhotoAsset
    let photoID: UUID // Added to track identity changes
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
                    Text("Could not load image")
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
                    print("ERROR: Failed to load image for photo ID: \(photo.id).")
                    loadingError = true
                }
            }
        }
    }
}
