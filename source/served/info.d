module served.info;

static immutable Version = [0, 7, 4];
static immutable VersionSuffix = ""; // like beta.1
static immutable string BundledDependencies = "dub, dfmt and dscanner are bundled within (compiled in)";

version (Windows) version (DigitalMars) static assert(false,
		"DMD not supported on Windows. Please use LDC.");
