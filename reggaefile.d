
import reggae;

alias buildTarget = dubDefaultTarget!(); // dub build
alias testTarget = dubTestTarget!();     // dub test (=> ut[.exe])

Target aliasTarget(string aliasName, alias target)() {
    import std.algorithm: map;
    // Using a leaf target with `$builddir/<raw output>` outputs as dependency
    // yields the expected relative target names for Ninja/make.
    return Target.phony(aliasName, "", Target(target.rawOutputs.map!(o => "$builddir/" ~ o), ""));
}

// Add a `default` convenience alias for the `dub build` target.
// Especially useful for Ninja (`ninja default ut` to build default & test targets in parallel).
alias defaultTarget = aliasTarget!("default", buildTarget);

version (Windows) {
    // Windows: extra `ut` convenience alias for `ut.exe`
    alias utTarget = aliasTarget!("ut", testTarget);
    mixin build!(buildTarget, optional!testTarget, optional!defaultTarget, optional!utTarget);
} else {
    mixin build!(buildTarget, optional!testTarget, optional!defaultTarget);
}
