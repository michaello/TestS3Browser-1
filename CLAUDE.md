---
description: 
globs: *.swift
alwaysApply: false
---

# Modern iOS SwiftUI App Development Requirements

## Core Technical Requirements
- iOS 18+ target
- Swift's Observation framework
- Structured concurrency with async/await
- SwiftUI navigation APIs
- Actor-based concurrency

## 1. Service Layer (Actors)

For logic heavy classes/actors/structs make extensive documentation:
```swift
@globalActor
 actor DataServiceActor {
static let shared = DataServiceActor()
/// Maintains in-memory cache of products, keyed by their unique identifiers
/// This cache is actor-isolated to prevent concurrent access issues
private var cache: [String: Product] = [:]
/// Tracks ongoing background tasks to prevent duplicate operations and enable cleanup
/// Key: Operation identifier, Value: Task reference for cancellation
private var activeTasks: [UUID: Task<Void, Never>] = [:]
/// Debounce timer for rapid sequential operations
/// Used to coalesce multiple requests into a single network call
private var debounceTimer: Timer?
/// Queue of pending operations awaiting processing
/// Operations are coalesced when possible to minimize network traffic
private var operationQueue: [PendingOperation] = []
// MARK: - Public Interface
/// Fetches product data with intelligent caching and deduplication
/// - Parameters:
///   - id: Product identifier
///   - force: Whether to bypass cache and force a fresh fetch
/// - Returns: Product data
/// - Throws: NetworkError, ValidationError, or CacheError
func fetchProduct(_ id: String, force: Bool = false) async throws -> Product {
// Fast path: return cached data if available and fresh
if !force, let cached = cache[id] {
if await isCacheValid(for: id) {
return cached
}
}
// Check for existing in-flight request to prevent duplicate fetches
if let existingTask = activeTasks[id] {
return try await withTaskCancellationHandler {
// Wait for existing request to complete
try await withCheckedThrowingContinuation { continuation in
// Implementation details...
}
} onCancel: {
existingTask.cancel()
}
}
// Create new fetch task
let task = Task {
try await performFetch(id)
}
activeTasks[id] = task
do {
let result = try await task.value
cache[id] = result
return result
} catch {
// Clean up on error
activeTasks[id] = nil
throw error
}
}
// MARK: - Private Implementation
/// Validates cache freshness based on business rules
/// - Parameter id: Product identifier to validate
/// - Returns: Boolean indicating if cache is still valid
private func isCacheValid(for id: String) async -> Bool {
// Complex cache validation logic...
}
/// Performs actual network fetch with retry logic and error handling
private func performFetch(_ id: String) async throws -> Product {
var attempts = 0
let maxAttempts = 3
// Exponential backoff retry logic
while attempts < maxAttempts {
do {
return try await networkFetch(id)
} catch let error as NetworkError {
attempts += 1
if attempts == maxAttempts { throw error }
// Calculate backoff duration
let backoffDuration = pow(2.0, Double(attempts)) * 0.1
try await Task.sleep(nanoseconds: UInt64(backoffDuration * 1_000_000_000))
}
}
throw NetworkError.maxRetriesExceeded
}
}
@Observable
 final class ComplexViewModel {
// MARK: - Types
/// Represents the various states of data processing
private enum ProcessingState {
case idle
case processing(Progress)
case validating
case error(Error)
var isProcessing: Bool {
if case .processing = self { return true }
return false
}
}
/// Tracks individual item processing status
private struct ItemStatus {

var state: ProcessingState = .idle
var retryCount: Int = 0
var lastAttempt: Date?
}
// MARK: - State
/// Current processing state for each item
private var itemStatus: [String: ItemStatus] = [:]
/// Queue of items pending processing
private var processingQueue: OrderedSet<String> = []
/// Active processing task
private var processingTask: Task<Void, Error>?
// MARK: - Public Interface
/// Initiates processing of items with intelligent batching and error handling
/// - Parameters:
///   - items: Items to process
///   - batchSize: Maximum items to process concurrently
func processItems(_ items: [String], batchSize: Int = 3) async throws {
// Cancel any existing processing
processingTask?.cancel()
processingTask = Task {
// Group items into batches for efficient processing
let batches = items.chunks(ofCount: batchSize)
for batch in batches {
try Task.checkCancellation()
// Process batch with concurrency
try await withThrowingTaskGroup(of: Void.self) { group in
for item in batch {
group.addTask {
try await processItem(item)
}
}
// Wait for batch completion or handle errors
try await group.waitForAll()
}
// Validate batch results
try await validateBatchResults(batch)
}
}
try await processingTask?.value
}
// MARK: - Private Implementation
/// Processes a single item with retry logic and state management
/// - Parameter id: Item identifier
private func processItem(_ id: String) async throws {
var status = itemStatus[id] ?? ItemStatus()
// Check retry limits
guard status.retryCount < 3 else {
throw ProcessingError.maxRetriesExceeded
}
do {
status.state = .processing(Progress())
itemStatus[id] = status
// Actual processing implementation...
try await performProcessing(id)
status.state = .validating
itemStatus[id] = status
} catch {
status.retryCount += 1
status.lastAttempt = .now
status.state = .error(error)
itemStatus[id] = status
throw error
}
}
/// Validates results of a batch operation
/// - Parameter batch: Batch of items to validate
private func validateBatchResults(_ batch: [String]) async throws {
// Implementation of batch validation...
}
}
```
## 2. View Models
```swift
@Observable
 final class ProductViewModel {
// MARK: - State
var products: [Product] = []
var isLoading = false
var error: Error?
var currentState: ViewState = .idle
// MARK: - Dependencies
private let dataService: DataServiceActor
// MARK: - Navigation
var navigationPath = NavigationPath()
var presentedSheet: SheetType?
init(dataService: DataServiceActor = .shared) {
self.dataService = dataService
}
// MARK: - Lifecycle
func onAppear() async {
await loadProducts()
}
// MARK: - Operations
func loadProducts() async {
isLoading = true
defer { isLoading = false }
do {
let data = try await dataService.fetchProducts()
await http://MainActor.run {
self.products = data
self.currentState = .loaded
}
} catch {
await http://MainActor.run {
self.error = error
self.currentState = .error(error)
}
}
}
}
```

## 3. Views

For Views and simpler ViewModels, we can use lighter documentation:
```
struct ProductListView: View {
@State private var viewModel = ProductListViewModel()
var body: some View {
content
}
private var content: some View {
List {
ForEach(viewModel.products) { product in
productRow(product)
}
}
.task {
await viewModel.loadProducts()
}
}
}
@Observable
 final class ProductListViewModel {
var products: [Product] = []
var isLoading = false
func loadProducts() async {
isLoading = true
defer { isLoading = false }
do {
products = try await loadProductsFromService()
} catch {
// Handle error...
}
}
}
```
## 4. Actor-Based Data Flow
```swift
// Service Actor
@globalActor
 actor ProductServiceActor {
static let shared = ProductServiceActor()
private var cache: [String: Product] = [:]
private var refreshTask: Task<Void, Never>?
nonisolated let syncController: SyncController
func fetchProduct(_ id: String) async throws -> Product {
if let cached = cache[id] { return cached }
let product = try await performFetch(id)
cache[id] = product

return product

}
}
// View Model Integration
@Observable
 final class ProductDetailViewModel {
var product: Product?
var isLoading = false
private let serviceActor: ProductServiceActor
func loadProduct(id: String) async {
isLoading = true
defer { isLoading = false }
do {
// Safe actor access
let result = try await serviceActor.fetchProduct(id)
await http://MainActor.run { self.product = result }
} catch {
await handleError(error)
}
}
}
```

## 5. Error Handling
```swift
enum AppError: Error {
case network(NetworkError)
case data(DataError)
case user(UserError)
}
extension View {
func handleError(_ error: Error?) -> some View {
alert(isPresented: .constant(error != nil)) {
Alert(
title: Text("Error"),
message: Text(error?.localizedDescription ?? ""),
dismissButton: .default(Text("OK"))
)
}

}

}
```
## 6. Navigation
```swift
struct ContentView: View {
@State private var viewModel = ContentViewModel()
var body: some View {
NavigationStack(path: $viewModel.navigationPath) {
content
.navigationDestination(for: Product.self) { product in
ProductDetailView(product: product)
}
.sheet(item: $viewModel.presentedSheet) { sheet in
sheetContent(for: sheet)
}
}
}

}
```
## Implementation Guidelines
1. Actor Safety:
- Always access actor state through async calls
- Use proper task management
- Handle cancellation
- Maintain actor isolation
2. View Models:
- Mark with @Observable, but only classes, and only if needed (not for structs)
- Use final classes
- Keep state in observable properties
- Handle loading states
- Manage errors properly
- Safe actor access
- Details from Apple: Starting with iOS 17, iPadOS 17, macOS 14, tvOS 17, and watchOS 10, SwiftUI provides support for Observation, a Swift-specific implementation of the observer design pattern. Adopting Observation provides your app with these benefits:

- Tracking optionals and collections of objects.
- Using data flow primitives like State and Environment.
- Updating views based solely on observable properties read directly by the view's body, enhancing performance.

To implement Observation, perform these steps:

### Apply the Observable Macro

Replace existing data model declarations with the `@Observable` macro:

```swift
import SwiftUI

@Observable class Library {
    var books: [Book] = [Book(), Book(), Book()]
}
```

- Remove any `@Published` property wrappers. Observable properties are determined by accessibility, not wrappers.
- To exclude a property from observation, use the `@ObservationIgnored` macro.

### Update Data Flow Management

- Replace `@StateObject` with `@State` and update environment usage:

```swift
@main
struct BookReaderApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
        }
    }
}
```

- Access observable objects from the environment using `@Environment`:

```swift
struct LibraryView: View {
    @Environment(Library.self) private var library

    var body: some View {
        List(library.books) { book in
            BookView(book: book)
        }
    }
}
```

### Modify Individual Observable Objects

Update your model types with the `@Observable` macro and remove all wrappers:

```swift
@Observable class Book: Identifiable {
    var title = "Sample Book Title"
    let id = UUID()
}
```

- Remove `@ObservedObject` from views; Observable automatically tracks properties read directly by the view's body:

```swift
struct BookView: View {
    var book: Book
    @State private var isEditorPresented = false

    var body: some View {
        HStack {
            Text(book.title)
            Spacer()
            Button("Edit") {
                isEditorPresented = true
            }
        }
        .sheet(isPresented: $isEditorPresented) {
            BookEditView(book: book)
        }
    }
}
```

### Use Bindable for Bindings

For views requiring bindings, use the `@Bindable` property wrapper:

```swift
struct BookEditView: View {
    @Bindable var book: Book
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            TextField("Title", text: $book.title)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    dismiss()
                }

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
```

Keep in mind that @Observable doesn’t apply to structs.

3. Views:
- Own view model instance
- Use @State for local state
- Handle all states (loading/error)
- Break into computed properties

- Implement proper navigation

- Should have #Preview { XYZView() } at the end of the file where XYZView is the name of the view
4. State Management:
- Keep mutable state in actors
- Use MainActor for UI updates
- Handle async operations safely
- Proper error propagation

5. Best Practices:
- Task cancellation
- Very rich prints into console if error happened for later troubleshooting, including class, and line number in the code
- Resource cleanup
- Error handling
- State restoration
- Memory management
6. Check for existing ...App.swift / AppMain.swift file. If not, create one. Use it to configure first screen of the app.
7. Model structure:
- Assume all fields are optional and cannot be guaranteed by API
8. Project structure
- Any new folders and files should be put into Sources folder inside the project. For instance, I have a project FooProject as top folder. It will have Sources. So if you want to make FooServiceActor.swift, you will make a folder Services, put FooServiceActor.swift, and this folder will be inside Sources. So it will be ./Sources/Services/FooServiceActor.swift

## 9. Exporting as Mac Catalyst App

To create a separate Mac app from an existing iOS iPad app using Mac Catalyst:

### Step 1: Enable Mac Catalyst Support in Xcode Project

Modify `TestS3Browser.xcodeproj/project.pbxproj` to add Mac Catalyst support:

```bash
# Add SUPPORTS_MACCATALYST = YES and update TARGETED_DEVICE_FAMILY to "1,2,6"
# (1=iPhone, 2=iPad, 6=Mac)
sed -i '' 's/TARGETED_DEVICE_FAMILY = "1,2";/SUPPORTS_MACCATALYST = YES;\n\t\t\tTARGETED_DEVICE_FAMILY = "1,2,6";/g' YourProject.xcodeproj/project.pbxproj
```

Verify changes applied:
```bash
grep "SUPPORTS_MACCATALYST" YourProject.xcodeproj/project.pbxproj
```

### Step 2: Create ExportOptions.plist

Create `ExportOptions.plist` in project root:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>mac-application</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>stripSwiftSymbols</key>
	<true/>
</dict>
</plist>
```

### Step 3: Archive for macOS

```bash
xcodebuild -scheme YourSchemeName \
  -destination generic/platform=macOS \
  -archivePath /tmp/YourApp-Mac.xcarchive \
  -configuration Release \
  archive
```

### Step 4: Export Archive

```bash
xcodebuild -exportArchive \
  -archivePath /tmp/YourApp-Mac.xcarchive \
  -exportOptionsPlist ./ExportOptions.plist \
  -exportPath /tmp/YourApp-MacExport
```

Result is `YourApp.app` in `/tmp/YourApp-MacExport`. This is a universal binary (x86_64 + arm64).

### Step 5: Verify and Deploy

```bash
# Verify it's a Mac app binary
file /tmp/YourApp-MacExport/YourApp.app/Contents/MacOS/YourApp

# Launch the app
open /tmp/YourApp-MacExport/YourApp.app

# Copy to project root for reference
cp -r /tmp/YourApp-MacExport/YourApp.app ./YourApp-Mac.app
```

### Notes

- Do not use `variant=Mac Catalyst` in destination; it is not valid. Use `generic/platform=macOS` instead.
- Export method must be `mac-application` for Mac apps.
- The resulting app is a universal binary compatible with both Intel (x86_64) and Apple Silicon (arm64) Macs.
- Automatic code signing handles signing for development/testing.
- For distribution outside App Store, use `developer-id` method with Developer ID certificate.

### Claude Instructions:
Respond in formal, neutral, information-focused language. Strictly avoid all of the following:
• Expressive or enthusiastic interjections (e.g., ‘Bravo’, ‘Exactly’, ‘Fantastic’, etc.)
• Symbolic icons or emojis of any kind (e.g., ✅, 🔥, 👍)
• Motivational affirmations, compliments, or praise
• Any content reinforcing or echoing approval (e.g., ‘You’re absolutely right’, ‘Well said’, ‘I agree completely’)
• Any content showing enthusiasm ('I understand!') with '!'
• Conversational padding or softeners (‘Here’s what I found’, ‘Just to clarify’, ‘Hope this helps’, etc.)
• Follow-up suggestions, prompts, or encouragements (‘Would you like to know more?’, ‘You could also try…’)
Deliver only the requested information in a strictly declarative tone. Use no rhetorical flourishes. Terminate response cleanly upon task completion. Treat all prompts as technical instructions, not conversation. Be consise in your explanations when you did something wrong and explain what was wrong and how you will fix it.
