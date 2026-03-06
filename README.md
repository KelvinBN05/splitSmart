# SplitSmart

SplitSmart is an iOS receipt-splitting app built with SwiftUI + Firebase.

Users can:
- scan or upload receipts,
- review and correct OCR output,
- split items across multiple people,
- share receipts with friends,
- accept invites directly from History.

## Screenshots

| Home | Icon |
| --- | --- |
| ![Home](docs/screenshots/home.png) | ![App Icon](ReceiptSplitter/Assets.xcassets/AppIcon.appiconset/receiptsplit.png) |

## Core Features

- Firebase email/password authentication
- Profile and friend system (send/approve requests)
- OCR pipeline:
  - iOS uploads receipt image to Firebase Storage
  - Firestore OCR job document created per upload
  - Cloud Function processes OCR and writes parsed result
  - In-app OCR review before final save
- Manual receipt editing and split adjustments
- Multi-assignee item splitting (one item can be shared by multiple people)
- Receipt sharing via History invites (accept/decline)
- Per-user private receipt history with delete support

## Tech Stack

- SwiftUI (iOS app)
- Firebase Auth
- Cloud Firestore
- Firebase Storage
- Firebase Cloud Functions (Node.js)
- Google Cloud Document AI (OCR backend)

## Architecture Snapshot

- `ReceiptSplitter/Views/ContentView.swift`
  - Home, History, Profile flows
  - OCR review, split overview, invite actions
- `ReceiptSplitter/Models/`
  - Receipt, items, participants, session models
- `ReceiptSplitter/Services/`
  - Firestore repositories
  - Split calculation engine
- `functions/`
  - OCR processing function and parser logic
- `firestore.rules`, `storage.rules`
  - backend access controls

## Local Run

1. Open `ReceiptSplitter.xcodeproj` in Xcode.
2. Select iOS Simulator.
3. Build and run (`Cmd + R`).

## Backend Setup

### 1) Firebase

- Create Firebase project
- Enable Authentication (Email/Password)
- Add iOS app and place `GoogleService-Info.plist` in `ReceiptSplitter/`
- Enable Firestore + Storage

### 2) Functions + Rules Deploy

```bash
cd "/Users/kelvinnguyen/Documents/Projects/Receipt App/splitSmart/functions"
npm install

cd "/Users/kelvinnguyen/Documents/Projects/Receipt App/splitSmart"
firebase deploy --only firestore:rules,storage,functions --project recieptsplitter
```

### 3) Document AI config

Set function config (values from your GCP processor):

```bash
firebase functions:config:set \
  document_ai.project_id="recieptsplitter" \
  document_ai.location="us" \
  document_ai.processor_id="YOUR_PROCESSOR_ID"
```

Then redeploy functions.

## Testing

### iOS tests

```bash
xcodebuild test -project ReceiptSplitter.xcodeproj -scheme ReceiptSplitter -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

### Functions/parser tests

```bash
cd functions
npm test
```


## Current Status

Actively developed. Current focus is final UI polish, parser quality improvements, and broader automated test coverage for OCR edge cases.
