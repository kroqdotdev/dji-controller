## What does this change?

## How was it tested?

- [ ] `xcodebuild -scheme Lavboard test` passes, and `swift test` in any package I changed
- [ ] Tested with a receiver (describe the setup below), or not needed for this change

## Checklist

- [ ] UI changes include a screenshot
- [ ] No destructive receiver commands (such as the DJI `0x07` format and `0x23` reboot) are sent without user confirmation
- [ ] New mic system: hardware, firmware and modes tested are listed above, and the README table is updated
- [ ] `Vendor/BlackHole` is unmodified
