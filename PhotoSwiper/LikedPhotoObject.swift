//
//  LikedPhotoObject.swift
//  PhotoSwiper
//
//  Created by Henrique Leote on 20.05.25.
//


// LikedPhotoObject.swift
import Foundation
import RealmSwift

class LikedPhotoObject: Object {
    @Persisted(primaryKey: true) var id: String = "" // This will store the PHAsset.localIdentifier
    @Persisted var dateAdded: Date = Date() // Optional: Useful for tracking when it was ignored

    convenience init(id: String) {
        self.init()
        self.id = id
        self.dateAdded = Date()
    }
}
