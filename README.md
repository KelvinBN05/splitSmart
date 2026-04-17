# SplitSmart

SplitSmart is an iOS app for scanning receipts, reviewing OCR output, and splitting expenses across friends or custom participants.

## What It Does

- Scan a receipt with the camera or import a photo
- Parse line items, quantities, and totals with a cloud OCR pipeline
- Review and correct OCR results before saving
- Split items across one or more people
- Share receipts with friends and track them in History
- Save private receipt history per user

## Tech Stack

- SwiftUI
- Firebase Auth
- Cloud Firestore
- Firebase Storage
- Firebase Cloud Functions (Node.js)
- Google Cloud Document AI

## Repo Layout

- `ReceiptSplitter/` - iOS app source
- `ReceiptSplitterTests/` - iOS unit tests
- `functions/` - OCR parsing and backend logic
- `docs/screenshots/` - README assets
- `firestore.rules` - Firestore access rules
- `storage.rules` - Storage access rules

## Screenshot

![SplitSmart home screen](docs/screenshots/home.png)

## Running the App

1. Open `ReceiptSplitter.xcodeproj` in Xcode.
2. Select an iOS simulator or device.
3. Build and run with `Cmd + R`.

## Backend Setup

1. Create a Firebase project.
2. Enable:
   - Email/Password Authentication
   - Firestore
   - Storage
3. Add your iOS app and place `GoogleService-Info.plist` in `ReceiptSplitter/`.
4. Install function dependencies:

```bash
cd functions
npm install
```

5. Deploy backend resources:

```bash
firebase deploy --only firestore:rules,storage,functions --project recieptsplitter
```

## Testing

### iOS tests

```bash
xcodebuild test -project ReceiptSplitter.xcodeproj -scheme ReceiptSplitter -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

### Functions tests

```bash
cd functions
npm test
```
