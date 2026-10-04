// Force-included before Vendor/BlackHole/BlackHole.c (see project.yml). BlackHole guards each of
// these with #ifndef, so this file turns it into the "DJI Controller" stream device without
// editing the GPL source.

#define kDriver_Name                "DJI Controller"
#define kPlugIn_BundleID            "com.sauerdev.djicontroller.stream"
#define kPlugIn_Icon                "StreamDevice.icns"
#define kHas_Driver_Name_Format     false
#define kDevice_Name                "DJI Controller"
#define kManufacturer_Name          "DJI Controller"
#define kNumber_Of_Channels         2

// The app sets the level; a volume slider on the device itself would only cause confusion.
#define kEnableVolumeControl        false

// Never let macOS pick it as the default input/output or route system sounds into the stream.
#define kCanBeDefaultDevice         false
#define kCanBeDefaultSystemDevice   false

// The receiver only runs at 48 kHz.
#define kSampleRates                48000
