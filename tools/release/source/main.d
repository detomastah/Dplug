import std.process;
import std.file;
import std.stdio;
import std.string;
import std.path;
import std.conv;
import std.uuid;


// Builds plugins and make an archive

void usage()
{
    writeln("usage: release -c <compiler> -a <arch> -b <build>");
    writeln("  -a                selects arch x86|x64|all (default: win => all   mac => x64)");
    writeln("  -b                selects builds (default: release-nobounds)");
    writeln("  -c                selects compiler dmd|ldc|gdc|all (default: ldc)");
    writeln("  --config          selects configuration VST|AU|<other> (default: VST)");
    writeln("  -f|--force        selects compiler dmd|ldc|gdc|all (default: no)");
    writeln("  -comb|--combined  combined build (default: no)");
    writeln("  -h|--help         shows this help");
}

enum Compiler
{
    ldc,
    gdc,
    dmd,
    all
}

enum Arch
{
    x86,
    x64,
    universalBinary
}

Arch[] allArchitectureqForThisPlatform()
{
    Arch[] archs = [Arch.x86, Arch.x64];
    version (OSX)
        archs ~= [Arch.universalBinary]; // only Mac has universal binaries
    return archs;
}

string toString(Arch arch)
{
    final switch(arch) with (Arch)
    {
        case x86: return "32-bit";
        case x64: return "64-bit";
        case universalBinary: return "Universal-Binary";
    }
}

int main(string[] args)
{
    // TODO get executable name from dub.json
    try
    {
        Compiler compiler = Compiler.ldc; // use LDC by default

        Arch[] archs = allArchitectureqForThisPlatform();
        version (OSX)
            archs = [ Arch.x64 ];

        string build="debug";
        string config = "VST";
        bool verbose = false;
        bool force = false;
        bool combined = false;
        bool help = false;

        string osString = "";
        version (OSX)
            osString = "Mac-OS-X";
        else version(linux)
            osString = "Linux";
        else version(Windows)
            osString = "Windows";


        for (int i = 1; i < args.length; ++i)
        {
            string arg = args[i];
            if (arg == "-v")
                verbose = true;
            else if (arg == "-c" || arg == "--compiler")
            {
                ++i;
                if (args[i] == "dmd")
                    compiler = Compiler.dmd;
                else if (args[i] == "gdc")
                    compiler = Compiler.gdc;
                else if (args[i] == "ldc")
                    compiler = Compiler.ldc;
                else if (args[i] == "all")
                    compiler = Compiler.all;
                else throw new Exception("Unrecognized compiler (available: dmd, ldc, gdc, all)");
            }
            else if (arg == "--config")
            {
                ++i;
                config = args[i];
            }
            else if (arg == "-comb"|| arg == "--combined")
                combined = true;
            else if (arg == "-a")
            {
                ++i;
                if (args[i] == "x86" || args[i] == "x32")
                    archs = [ Arch.x86 ];
                else if (args[i] == "x64" || args[i] == "x86_64")
                    archs = [ Arch.x64 ];
                else if (args[i] == "all")
                {
                    archs = allArchitectureqForThisPlatform();
                }
                else throw new Exception("Unrecognized arch (available: x86, x32, x64, x86_64, all)");
            }
            else if (arg == "-h" || arg == "-help" || arg == "--help")
                help = true;
            else if (arg == "-b")
            {
                build = args[++i];
            }
            else if (arg == "-f" || arg == "--force")
                force = true;
            else
                throw new Exception(format("Unrecognized argument %s", arg));
        }

        if (help)
        {
            usage();
            return 0;
        }

        Plugin plugin = readDubDescription();
        string dirName = "builds";

        void fileMove(string source, string dest)
        {
            std.file.copy(source, dest);
            std.file.remove(source);
        }

        auto oldpath = environment["PATH"];

        static string outputDirectory(string dirName, string osString, Arch arch, string config)
        {
            return format("%s/%s-%s-%s", dirName, osString, toString(arch), config); // no spaces because of lipo call
        }

        void buildAndPackage(string compiler, string config, Arch[] architectures, string iconPath)
        {
            foreach (arch; architectures)
            {
                bool is64b = arch == Arch.x64;
                version(Windows)
                {
                    // TODO: remove when LDC on Windows is a single archive (should happen for 1.0.0)
                    // then fiddling with PATH will be useless
                    if (compiler == "ldc" && !is64b)
                        environment["PATH"] = `c:\d\ldc-32b\bin` ~ ";" ~ oldpath;
                    if (compiler == "ldc" && is64b)
                        environment["PATH"] = `c:\d\ldc-64b\bin` ~ ";" ~ oldpath;
                }

                // Create a .rsrc for this set of architecture when building an AU
                string rsrcPath = null;
                version(OSX)
                {
                    // Make icns and copy it (if any provided in dub.json)
                    if (configIsAU(config))
                    {
                        rsrcPath = makeRSRC(plugin.name, arch, verbose);
                    }
                }

                string path = outputDirectory(dirName, osString, arch, config);

                writefln("Creating directory %s", path);
                mkdirRecurse(path);

                if (arch != Arch.universalBinary)
                    buildPlugin(compiler, config, build, is64b, verbose, force, combined);

                version(Windows)
                {
                    string appendBitness(string filename)
                    {
                        if (is64b)
                        {
                            // Issue #84
                            // Rename 64-bit binary on Windows to get Reaper to list both 32-bit and 64-bit plugins if in the same directory
                            return stripExtension(filename) ~ "-64" ~ extension(filename);
                        }
                        else
                            return filename;
                    }

                    // On Windows, simply copy the file
                    fileMove(plugin.outputFile, path ~ "/" ~ appendBitness(plugin.outputFile));
                }
                else version(OSX)
                {
                    // Only accepts two configurations: VST and AudioUnit
                    string pluginDir;
                    if (configIsVST(config))
                        pluginDir = plugin.name ~ ".vst";
                    else if (configIsAU(config))
                        pluginDir = plugin.name ~ ".component";
                    else
                        pluginDir = plugin.name;

                    // On Mac, make a bundle directory
                    string contentsDir = path ~ "/" ~ pluginDir ~ "/Contents";
                    string ressourcesDir = contentsDir ~ "/Resources";
                    string macosDir = contentsDir ~ "/MacOS";
                    mkdirRecurse(ressourcesDir);
                    mkdirRecurse(macosDir);

                    string plist = makePListFile(plugin, config, iconPath != null);
                    std.file.write(contentsDir ~ "/Info.plist", cast(void[])plist);

                    std.file.write(contentsDir ~ "/PkgInfo", cast(void[])makePkgInfo());

                    if (iconPath)
                        std.file.copy(iconPath, contentsDir ~ "/Resources/icon.icns");

                    string exePath = macosDir ~ "/" ~ plugin.name;

                    // Copy .rsrc file (if needed)
                    if (rsrcPath)
                        std.file.copy(rsrcPath, contentsDir ~ "/Resources/" ~ baseName(exePath) ~ ".rsrc");

                    if (arch == Arch.universalBinary)
                    {
                        string path32 = outputDirectory(dirName, osString, Arch.x86, config)
                        ~ "/" ~ pluginDir ~ "/Contents/MacOS/" ~plugin.name;

                        string path64 = outputDirectory(dirName, osString, Arch.x64, config)
                        ~ "/" ~ pluginDir ~ "/Contents/MacOS/" ~plugin.name;

                        writefln("*** Making an universal binary with lipo");

                        string cmd = format("lipo -create %s %s -output %s", path32, path64, exePath);
                        safeCommand(cmd);
                    }
                    else
                    {
                        fileMove(plugin.outputFile, exePath);
                    }
                }
            }
        }

        bool hasDMD = compiler == Compiler.dmd || compiler == Compiler.all;
        bool hasGDC = compiler == Compiler.gdc || compiler == Compiler.all;
        bool hasLDC = compiler == Compiler.ldc || compiler == Compiler.all;

        mkdirRecurse(dirName);

        string iconPath = null;
        version(OSX)
        {
            // Make icns and copy it (if any provided in dub.json)
            if (plugin.iconPath)
            {
                iconPath = makeMacIcon(plugin.name, plugin.iconPath); // TODO: this should be lazy
            }
        }

        // Copy license (if any provided in dub.json)
        if (plugin.licensePath)
            std.file.copy(plugin.licensePath, dirName ~ "/" ~ baseName(plugin.licensePath));

        // Copy user manual (if any provided in dub.json)
        if (plugin.userManualPath)
            std.file.copy(plugin.userManualPath, dirName ~ "/" ~ baseName(plugin.userManualPath));



        // DMD builds
        if (hasDMD) buildAndPackage("dmd", config, archs, iconPath);
        if (hasGDC) buildAndPackage("gdc", config, archs, iconPath);
        if (hasLDC) buildAndPackage("ldc", config, archs, iconPath);
        return 0;
    }
    catch(ExternalProgramErrored e)
    {
        writefln("error: %s", e.msg);
        return e.errorCode;
    }
    catch(Exception e)
    {
        writefln("error: %s", e.msg);
        return -1;
    }
}

class ExternalProgramErrored : Exception
{
    public
    {
        @safe pure nothrow this(int errorCode,
                                string message,
                                string file =__FILE__,
                                size_t line = __LINE__,
                                Throwable next = null)
        {
            super(message, file, line, next);
            this.errorCode = errorCode;
        }

        int errorCode;
    }
}


void safeCommand(string cmd)
{
    writefln("*** %s", cmd);
    auto pid = spawnShell(cmd);
    auto errorCode = wait(pid);
    if (errorCode != 0)
        throw new ExternalProgramErrored(errorCode, format("Command '%s' returned %s", cmd, errorCode));
}

void buildPlugin(string compiler, string config, string build, bool is64b, bool verbose, bool force, bool combined)
{
    if (compiler == "ldc")
        compiler = "ldc2";

    version(linux)
    {
        combined = true; // for -FPIC
    }

    // On OSX, 32-bit plugins made with LDC are compatible >= 10.7
    // while those made with DMD >= 10.6
    // So force DMD usage for 32-bit plugins.
    // UPDATE: no longer support 10.6, D dropped compatibility and 64-bit was untested
    /*
    if ( (is64b == false) && (compiler == "ldc2") )
    {
        writefln("info: forcing DMD compiler for 10.6 compatibility");
        compiler = "dmd";
    }
    */

    writefln("*** Building with %s, %s arch", compiler, is64b ? "64-bit" : "32-bit");
    // build the output file
    string arch = is64b ? "x86_64" : "x86";

    // Produce output compatible with earlier OSX
    // LDC does not support earlier than 10.7
    version(OSX)
    {
        environment["MACOSX_DEPLOYMENT_TARGET"] = "10.7";
    }

    string cmd = format("dub build --build=%s --arch=%s --compiler=%s %s %s %s %s",
        build, arch,
        compiler,
        force ? "--force" : "",
        verbose ? "-v" : "",
        combined ? "--combined" : "",
        config ? "--config=" ~ config : ""
        );
    safeCommand(cmd);
}


struct Plugin
{
    string name;       // name, extracted from dub.json
    string ver;        // version information
    string outputFile; // result of build
    string copyright;  // Copyright information, copied in the bundle
    string CFBundleIdentifierPrefix;
    string userManualPath; // can be null
    string licensePath;    // can be null
    string iconPath;       // can be null or a path to a (large) .png
}

Plugin readDubDescription()
{
    Plugin result;
    auto dubResult = execute(["dub", "describe"]);

    if (dubResult.status != 0)
        throw new Exception(format("dub returned %s", dubResult.status));

    import std.json;
    JSONValue description = parseJSON(dubResult.output);

    string mainPackage = description["mainPackage"].str;

    foreach (pack; description["packages"].array())
    {
        string name = pack["name"].str;
        if (name == mainPackage)
        {
            result.name = name;
            result.ver = pack["version"].str;
            result.outputFile = pack["targetFileName"].str;

            string copyright = pack["copyright"].str;

            if (copyright == "")
            {
                version(OSX)
                {
                    throw new Exception("Your dub.json is missing a non-empty \"copyright\" field to put in Info.plist");
                }
                else
                    writeln("warning: missing \"copyright\" field in dub.json");
            }
            result.copyright = copyright;
        }
    }

    // Open dub.json directly to find keys that DUB doesn't bypass
    JSONValue rawDubFile = parseJSON(cast(string)(std.file.read("dub.json")));

    try
    {
        result.CFBundleIdentifierPrefix = rawDubFile["CFBundleIdentifierPrefix"].str;
    }
    catch(Exception e)
    {
        version (OSX)
            throw new Exception("Your dub.json is missing a non-empty \"CFBundleIdentifierPrefix\" field to put in Info.plist");
        else
            writeln("warning: missing \"CFBundleIdentifierPrefix\" field in dub.json");
    }

    try
    {
        result.userManualPath = rawDubFile["userManualPath"].str;
    }
    catch(Exception e)
    {
        writeln("info: no \"userManualPath\" provided in dub.json");
    }

    try
    {
        result.licensePath = rawDubFile["licensePath"].str;
    }
    catch(Exception e)
    {
        writeln("info: no \"licensePath\" provided in dub.json");
    }

    try
    {
        result.iconPath = rawDubFile["iconPath"].str;
    }
    catch(Exception e)
    {
        writeln("info: no \"iconPath\" provided in dub.json");
    }
    return result;
}

bool configIsVST(string config)
{
    return config.length >= 3 && config[0..3] == "VST";
}

bool configIsAU(string config)
{
    return config.length >= 2 && config[0..2] == "AU";
}

string makePListFile(Plugin plugin, string config, bool hasIcon)
{
    string productName = plugin.name;
    string copyright = plugin.copyright;

    string productVersion = "1.0.0";
    string content = "";

    content ~= `<?xml version="1.0" encoding="UTF-8"?>` ~ "\n";
    content ~= `<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">` ~ "\n";
    content ~= `<plist version="1.0">` ~ "\n";
    content ~= `    <dict>` ~ "\n";

    void addKeyString(string key, string value)
    {
        content ~= format("        <key>%s</key>\n        <string>%s</string>\n", key, value);
    }

    addKeyString("CFBundleDevelopmentRegion", "English");

    addKeyString("CFBundleGetInfoString", productVersion ~ ", " ~ copyright);

    string CFBundleIdentifier;
    if (configIsVST(config))
        CFBundleIdentifier = plugin.CFBundleIdentifierPrefix ~ ".vst." ~ plugin.name;
    else if (configIsAU(config))
        CFBundleIdentifier = plugin.CFBundleIdentifierPrefix ~ ".audiounit." ~ plugin.name;
    else
    {
        writeln(`warning: your configuration name doesn't start with "VST" or "AU"`);
        CFBundleIdentifier = plugin.CFBundleIdentifierPrefix ~ "." ~ plugin.name;
    }
    addKeyString("CFBundleIdentifier", CFBundleIdentifier);

    // This doesn't seem needed afterall
    /*if (configIsAU(config))
    {
        addKeyString("NSPrincipalClass", "dplug_view");
    }*/

    if (configIsAU(config))
    {
        content ~= "<key>AudioComponents</key>";
        content ~= "<array>";
        content ~= "    <dict>";
        content ~= "        <key>type</key>";
        content ~= "        <string>aufx</string>";
        content ~= "        <key>subtype</key>";
        content ~= "        <string>XMPL</string>";
        content ~= "        <key>manufacturer</key>";
        content ~= "        <string>ACME</string>";
        content ~= "        <key>name</key>";
        content ~= format("        <string>%s</string>", plugin.name);
        content ~= "        <key>version</key>";
        content ~= format("        <integer>%s</integer>", plugin.ver);
        content ~= "        <key>factoryFunction</key>";
        content ~= "        <string>AUFactoryFunction</string>";
        content ~= "        <key>sandboxSafe</key><true/>";
        content ~= "    </dict>";
        content ~= "</array>";
    }

    addKeyString("CFBundleInfoDictionaryVersion", "6.0");
    addKeyString("CFBundlePackageType", "BNDL");
    addKeyString("CFBundleShortVersionString", productVersion);
    addKeyString("CFBundleSignature", "ABAB"); // doesn't matter http://stackoverflow.com/questions/1875912/naming-convention-for-cfbundlesignature-and-cfbundleidentifier
    addKeyString("CFBundleVersion", productVersion);
    addKeyString("LSMinimumSystemVersion", "10.7.0");
    if (hasIcon)
        addKeyString("CFBundleIconFile", "icon");
    content ~= `    </dict>` ~ "\n";
    content ~= `</plist>` ~ "\n";
    return content;
}

string makePkgInfo()
{
    return "BNDLABAB";
}

// return path of newly made icon
string makeMacIcon(string pluginName, string pngPath)
{
    string temp = tempDir();
    string iconSetDir = buildPath(tempDir(), pluginName ~ ".iconset");
    string outputIcon = buildPath(tempDir(), pluginName ~ ".icns");

    if(!outputIcon.exists)
    {
        //string cmd = format("lipo -create %s %s -output %s", path32, path64, exePath);
        try
        {
            safeCommand(format("mkdir %s", iconSetDir));
        }
        catch(Exception e)
        {
            writefln(" => %s", e.msg);
        }
        safeCommand(format("sips -z 16 16     %s --out %s/icon_16x16.png", pngPath, iconSetDir));
        safeCommand(format("sips -z 32 32     %s --out %s/icon_16x16@2x.png", pngPath, iconSetDir));
        safeCommand(format("sips -z 32 32     %s --out %s/icon_32x32.png", pngPath, iconSetDir));
        safeCommand(format("sips -z 64 64     %s --out %s/icon_32x32@2x.png", pngPath, iconSetDir));
        safeCommand(format("sips -z 128 128   %s --out %s/icon_128x128.png", pngPath, iconSetDir));
        safeCommand(format("sips -z 256 256   %s --out %s/icon_128x128@2x.png", pngPath, iconSetDir));
        safeCommand(format("iconutil --convert icns --output %s %s", outputIcon, iconSetDir));
    }
    return outputIcon;
}

string makeRSRC(string pluginName, Arch arch, bool verbose)
{
    writefln("Generating a .rsrc file for %s arch...", to!string(arch));
    string temp = tempDir();

    string rPath = buildPath(temp, "plugin.r");

    auto rFile = File(rPath, "w");
    static immutable string rFileBase = cast(string) import("plugin-base.r");

    rFile.writefln(`#define PLUG_NAME "%s"`, pluginName);
    rFile.writeln("#define PLUG_MFR_ID 'ABAB'");
    rFile.writeln("#define PLUG_VER 0x00010000"); // TODO change this

    rFile.writeln(rFileBase);
    rFile.close();

    string rsrcPath = buildPath(temp, "plugin.rsrc");

    string archFlags;
    final switch(arch) with (Arch)
    {
        case x86: archFlags = "-arch i386"; break;
        case x64: archFlags = "-arch x86_64"; break;
        case universalBinary: archFlags = "-arch i386 -arch x86_64"; break;
    }

    string verboseFlag = verbose ? " -p" : "";
    safeCommand(format("rez %s%s -t BNDL -o %s -useDF %s", archFlags, verboseFlag, rsrcPath, rPath));


    if (!exists(rsrcPath))
        throw new Exception(format("%s wasn't created", rsrcPath));

    if (getSize(rsrcPath) == 0)
        throw new Exception(format("%s is an empty file", rsrcPath));

    writefln("Written %s bytes to %s", getSize(rsrcPath), rsrcPath);

    return rsrcPath;
}