# SplitSmart

SplitSmart is an iOS app for scanning and splitting receipts across friends. This repo currently includes a polished SwiftUI home experience, a split calculation engine, and unit tests for money allocation.

## Current Features (Phase 1)

- Home dashboard modeled after modern finance/productivity apps
- Receipt domain models (`Receipt`, `ReceiptItem`, `Participant`)
- Split calculator for:
  - item ownership allocation
  - proportional tax distribution
  - proportional tip distribution
  - cent-level rounding safety
- Unit tests for split behavior and total validation

## Project Structure

- `ReceiptSplitter/ContentView.swift`: main tabs + home/history/profile UI
- `ReceiptSplitter/Models/`: core data models for receipt splitting
- `ReceiptSplitter/Services/SplitCalculator.swift`: split engine and allocation rules
- `ReceiptSplitterTests/SplitCalculatorTests.swift`: unit tests for split math

## Next Milestones

1. OCR scanning flow (VisionKit + text parsing)
2. Manual correction screen for OCR mistakes
3. Save/load receipts with persistence
4. Export/share split summary

## Run

1. Open `ReceiptSplitter.xcodeproj` in Xcode
2. Select an iOS Simulator
3. Build and run (`Cmd + R`)

## Test

Run tests in Xcode (`Cmd + U`) or with:

```bash
xcodebuild test -project ReceiptSplitter.xcodeproj -scheme ReceiptSplitter -destination 'platform=iOS Simulator,name=iPhone 16'
```
