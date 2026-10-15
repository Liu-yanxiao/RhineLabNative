import Foundation
import CoreGraphics
import ImageIO

enum MusicArtwork {
    private static let lock = NSLock()
    private static var images: [Int: CGImage] = [:]
    private static var order: [Int] = []
    private static var cachedImages: [URL: CGImage] = [:]
    private static var cachedOrder: [URL] = []
    private static var highImages: [URL: CGImage] = [:]
    private static var highOrder: [URL] = []
    private static var heroIndex: Int?
    private static var heroImage: CGImage?
    static func image(_ index: Int) -> CGImage? { lock.lock(); defer { lock.unlock() }; return heroIndex == index ? heroImage ?? images[index] : images[index] }
    static func cached(_ url: URL, high: Bool = false) -> CGImage? { lock.lock(); defer { lock.unlock() }; return high ? highImages[url] : cachedImages[url] }
    static func setHero(_ index: Int?) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard index != heroIndex else { return nil }
        let old = heroIndex; heroIndex = index; heroImage = nil; return old
    }
    static func cache(_ image: CGImage, url: URL, high: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if high {
            highImages[url] = image; highOrder.removeAll { $0 == url }; highOrder.append(url)
            while highOrder.count > 2 { highImages.removeValue(forKey: highOrder.removeFirst()) }
        } else {
            cachedImages[url] = image; cachedOrder.removeAll { $0 == url }; cachedOrder.append(url)
            while cachedOrder.count > 24 { cachedImages.removeValue(forKey: cachedOrder.removeFirst()) }
        }
    }
    static func clear() { lock.lock(); images.removeAll(); order.removeAll(); heroIndex = nil; heroImage = nil; lock.unlock() }
    static func remove(_ index: Int) { lock.lock(); images.removeValue(forKey: index); order.removeAll { $0 == index }; if heroIndex == index { heroImage = nil }; lock.unlock() }
    static func store(_ image: CGImage, index: Int, high: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if high { if heroIndex == index { heroImage = image }; return }
        images[index] = image; order.removeAll { $0 == index }; order.append(index)
        while order.count > 24 { images.removeValue(forKey: order.removeFirst()) }
    }
    static func thumbnail(_ data: Data, maxPixelSize: Int = 512) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                                      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
