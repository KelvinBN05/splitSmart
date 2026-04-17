# SplitSmart

SplitSmart is an iOS receipt-splitting app built with SwiftUI + Firebase.

Users can:
- scan or upload receipts,
- review and correct OCR output,
- split items across multiple people,
- share receipts with friends,
- accept invites directly from History.

The current UI is built around a finance-style layout system:
- a simplified login and create-account screen,
- a scan-first Home screen with clearer action hierarchy,
- card-based History and Profile screens,
- guided Manual Entry and Split Result flows with anchored bottom actions.

## Screenshots

| Home | Icon |
| --- | --- |
| ![Home](docs/screenshots/home.png) | ![App Icon](ReceiptSplitter/Assets.xcassets/AppIcon.appiconset/receiptsplit.png) |

Note: the screenshot in `docs/screenshots/home.png` may lag behind the latest in-repo UI updates.

## UI Demo

This is the current end-to-end product flow:

1. Open the app and sign in or create an account from the simplified auth card.
2. Land on Home and choose the primary receipt path:
   - tap **Scan Receipt** to open the document scanner,
   - tap **Upload Photo** to import from the library,
   - or use **Manual Entry** to build the split yourself.
3. Review OCR output before saving if the receipt was scanned or uploaded.
4. Use Manual Entry to add merchant details, participants, tax, tip, and item assignments.
5. Tap **Calculate Split** from the bottom action area to generate the per-person breakdown.
6. Save the result to History.
7. Reopen saved receipts from History, accept incoming receipt invites, or adjust split assignments later.
8. Manage profile details and friend requests from the Profile tab.

If you want a richer README demo later, the next step would be recording a short simulator GIF or MP4 and linking it here.

## Core Features

- Firebase email/password authentication
- Simplified sign-in and account creation flow
- Profile and friend system (send/approve requests)
- OCR pipeline:
  - iOS uploads receipt image to Firebase Storage
  - Firestore OCR job document created per upload
  - Cloud Function processes OCR and writes parsed result
  - In-app OCR review before final save
- Manual receipt editing with participant assignment chips and persistent calculate action
- Multi-assignee item splitting (one item can be shared by multiple people)
- Receipt sharing via History invites (accept/decline)
- Per-user private receipt history with delete support
- Split summary screen with per-person breakdown before saving

## Tech Stack

- SwiftUI (iOS app)
- Firebase Auth
- Cloud Firestore
- Firebase Storage
- Firebase Cloud Functions (Node.js)
- Google Cloud Document AI (OCR backend)

## Architecture Snapshot

- `ReceiptSplitter/Views/ContentView.swift`
  - app shell, theme tokens, banners, tab structure
- `ReceiptSplitter/Views/AuthGateView.swift`
  - sign-in and create-account experience
- `ReceiptSplitter/Views/HomeView.swift`
  - scan-first landing flow, quick actions, OCR status, recent activity
- `ReceiptSplitter/Views/HistoryView.swift`
  - invite actions, receipt cards, split overview entry
- `ReceiptSplitter/Views/AccountView.swift`
  - profile summary, friend requests, account sheet
- `ReceiptSplitter/Views/ManualEntryView.swift`
  - guided receipt editor and split results flow
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

Actively developed. Current focus is deeper UI refinement across the remaining subflows, parser quality improvements, and broader automated test coverage for OCR edge cases.
