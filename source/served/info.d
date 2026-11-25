module served.info;

static immutable Version = [0, 10, 0];
static immutable VersionSuffix = "master";
static immutable string BundledDependencies = "dub, dfmt and dscanner are bundled within (compiled in)";

version (Windows) version (DigitalMars) static assert(false,
		"DMD not supported on Windows. Please use LDC.");
