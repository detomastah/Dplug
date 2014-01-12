// See Steinberg VST license here: http://www.gersic.com/vstsdk/html/plug/intro.html#licence
module dplug.vst.client;

import core.stdc.stdlib,
       core.stdc.string,
       core.stdc.stdio;

import std.conv,
       std.typecons;

import gfm.core.alignedbuffer;

import dplug.plugin.client,
       dplug.plugin.daw,
       dplug.plugin.spinlock;

import dplug.vst.aeffectx;

//T* emplace(T, Args...)(T* chunk, auto ref Args args)
T mallocEmplace(T, Args...)(auto ref Args args)
{
    size_t len = __traits(classInstanceSize, T);
    void* p = cast(void*)malloc(len);
    return emplace!(T, Args)(p[0..len], args);
}


///
///
///                 VST client wrapper
///
///
class VSTClient
{
public:

    AEffect _effect;
    
    this(Client client, HostCallbackFunction hostCallback)
    {
        _messageQueue = new SpinlockedQueue!Message(256);
        _host.init(hostCallback, &_effect);
        _client = client; // copy

        _effect = _effect.init;

        _effect.magic = kEffectMagic;

        int flags = effFlagsCanReplacing;

        if ( client.getFlags() & Client.IsSynth )
        {
            flags |= effFlagsIsSynth;
            _host.wantEvents();
        }

        if ( client.getFlags() & Client.HasGUI )
            flags |= effFlagsHasEditor;

        _effect.flags = flags;
        _maxParams = client.params().length;
        _maxInputs = _effect.numInputs = _client.maxInputs();
        _maxOutputs = _effect.numOutputs = _client.maxOutputs();
        assert(_maxParams >= 0 && _maxInputs >= 0 && _maxOutputs >= 0);
        _effect.numParams = cast(int)(client.params().length);
        _effect.numPrograms = 0; // TODO implement presets
        _effect.version_ = client.getPluginVersion();
        _effect.uniqueID = client.getPluginID();
        _effect.processReplacing = &processReplacingCallback;
        _effect.dispatcher = &dispatcherCallback;
        _effect.setParameter = &setParameterCallback;
        _effect.getParameter = &getParameterCallback;
        _effect.user = cast(void*)(this);
        _effect.object = cast(void*)(this);
        _effect.processDoubleReplacing = &processDoubleReplacingCallback;

        //deprecated
        _effect.DEPRECATED_ioRatio = 1.0;
        _effect.DEPRECATED_process = &processCallback;

        // dummmy values
        _sampleRate = 44100.0f;
        _maxFrames = 128;
        _usedInputs = 0;
        _usedOutputs = 0;

        // GUI thread can allocate
        _inputScratchBuffer.length = _maxInputs;
        _outputScratchBuffer.length = _maxOutputs;

        for (int i = 0; i < _maxInputs; ++i)
            _inputScratchBuffer[i] = new AlignedBuffer!double();

        for (int i = 0; i < _maxOutputs; ++i)
            _outputScratchBuffer[i] = new AlignedBuffer!double();

        _inputPointers.length = _maxInputs;
        _outputPointers.length = _maxOutputs;

        resizeScratchBuffers(_maxFrames);
    }

private:

    VSTHostFromClientPOV _host;
    Client _client;
    
    float _sampleRate; // samplerate from opcode thread POV
    size_t _maxFrames; // max frames from opcode thread POV
    int _maxInputs;
    int _maxOutputs;
    int _maxParams;
    int _usedInputs;  // used inputs from opcode thread POV
    int _usedOutputs; // used outputs from opcode thread POV

    AlignedBuffer!double[] _inputScratchBuffer;  // input double buffer, one per possible input
    AlignedBuffer!double[] _outputScratchBuffer; // input double buffer, one per output
    double*[] _inputPointers;  // where processAudio will take its audio input, one per possible input
    double*[] _outputPointers; // where processAudio will output audio, one per possible output   

    // Lock-free message queue from opcode thread to audio thread.
    SpinlockedQueue!Message _messageQueue;

    bool isValidParamIndex(int i) pure const nothrow
    {
        return i >= 0 && i < _maxParams;
    }

    /// VST opcode dispatcher
    final VstIntPtr dispatcher(int opcode, int index, ptrdiff_t value, void *ptr, float opt)
    {
        // Important message from Cockos:
        // "Assume everything can (and WILL) run at the same time as your 
        // process/processReplacing, except:
        //   - effOpen/effClose
        //   - effSetChunk -- while effGetChunk can run at the same time as audio 
        //     (user saves project, or for automatic undo state tracking), effSetChunk 
        //     is guaranteed to not run while audio is processing.
        // So nearly everything else should be threadsafe."

        switch(opcode)
        {
            case effOpen: // opcode 0
                return 0;

            case effClose: // opcode 1
                return 0;

            case effSetProgram: // opcode 2
                // TODO
                return 0;

            case effGetProgram: // opcode 3
                return 0; // TODO

            case effSetProgramName: // opcode 4
                return 0; // TODO

            case effGetProgramName: // opcode 5, 
            {
                // currently always return ""
                char* p = cast(char*)ptr;
                *p = '\0'; 
                return 0; // TODO, max 23 chars
            }

            case effGetParamLabel: // opcode 6
            {
                char* p = cast(char*)ptr;
                if (!isValidParamIndex(index))
                    *p = '\0';
                else
                    stringNCopy(p, 8, _client.param(index).label());
                return 0;
            }

            case effGetParamDisplay: // opcode 7
            {
                char* p = cast(char*)ptr;
                if (!isValidParamIndex(index))
                    *p = '\0';
                else
                    _client.param(index).toStringN(p, 8);
                return 0;
            }

            case effGetParamName: // opcode 8
            { 
                char* p = cast(char*)ptr;
                if (!isValidParamIndex(index))
                    *p = '\0';
                else
                    stringNCopy(p, 32, _client.param(index).name());
                return 0;
            }

            case DEPRECATED_effGetVu: // opcode 9
            {
                return 0;
            }

            case effSetSampleRate: // opcode 10
            {
                _sampleRate = opt;
                _messageQueue.pushBack(Message(Message.Type.resetState, _maxFrames, 0, _sampleRate));
                return 0;
            }
           
            case effSetBlockSize: // opcode 11
            {
                if (value < 0) 
                    return 1;

                _maxFrames = value;
                _messageQueue.pushBack(Message(Message.Type.resetState, _maxFrames, 0, _sampleRate));
                return 0;
            }

            case effMainsChanged: // opcode 12
                {
                    if (value == 0)
                    {
                      // Audio processing was switched off.
                      // The plugin must call flush its state because otherwise pending data 
                      // would sound again when the effect is switched on next time.
                      _messageQueue.pushBack(Message(Message.Type.resetState, _maxFrames, 0, _sampleRate));
                    }
                    else
                    {
                        // Audio processing was switched on.
                    }
                    return 0; // TODO, plugin should clear its state
                }

            case effEditGetRect: // opcode 13
                // TODO
                return 0;

            case effEditOpen: // opcode 14
                {
                    if ( _client.getFlags() & Client.HasGUI )
                    {
                        _client.onOpenGUI();
                        return 1;
                    }
                    else
                        return 0;
                }

            case effEditClose: // opcode 15
                {
                    if ( _client.getFlags() & Client.HasGUI )
                    {
                        _client.onCloseGUI();
                        return 1;
                    }
                    else
                        return 0;
                }

            case DEPRECATED_effEditDraw: // opcode 16
            case DEPRECATED_effEditMouse: // opcode 17
            case DEPRECATED_effEditKey: // opcode 18
                return 0;

            case effEditIdle: // opcode 19
                return 0; // why would it be useful to do anything?

            case DEPRECATED_effEditTop: // opcode 20, edit window has topped                
                return 0;

            case DEPRECATED_effEditSleep:  // opcode 21, edit window goes to background
                return 0;

            case DEPRECATED_effIdentify: // opcode 22
                return CCONST ('N', 'v', 'E', 'f');

            case effGetChunk: // opcode 23
                return 0; // TODO

            case effSetChunk: // opcode 24
                return 0; // TODO

            case effProcessEvents: // opcode 25, "host usually call ProcessEvents just before calling ProcessReplacing"
                return 0; // TODO

            case effCanBeAutomated: // opcode 26
            {
                if (!isValidParamIndex(index))
                    return 0;
                return 1; // can always be automated
            }

            case effString2Parameter: // opcode 27
            {
                if (!isValidParamIndex(index))
                    return 0;

                if (ptr == null)
                    return 0;

                double v;
                _client.param(index).set(atof(cast(char*)ptr));
                return 1;
            }

            case DEPRECATED_effGetNumProgramCategories: // opcode 28
                return 1; // no real program categories

            case effGetProgramNameIndexed: // opcode 29
            {
                // currently always return ""
                char* p = cast(char*)ptr;
                *p = '\0';
                return 1; // TODO
            }

            case DEPRECATED_effCopyProgram: // opcode 30
            case DEPRECATED_effConnectInput: // opcode 31
            case DEPRECATED_effConnectOutput: // opcode 32
                return 0;

            case effGetInputProperties: // opcode 33
            {
                if (ptr == null)
                    return 0;

                if (!_client.isValidInputIndex(index))
                    return 0;

                VstPinProperties* pp = cast(VstPinProperties*) ptr;
                pp.flags = kVstPinIsActive;
                    
                if ( (index % 2) == 0 && index < _client.maxInputs())
                    pp.flags |= kVstPinIsStereo;

                sprintf(pp.label.ptr, "Input %d", index);
                return 1;
            }

            case effGetOutputProperties: // opcode 34
            {
                if (ptr == null)
                    return 0;

                if (!_client.isValidOutputIndex(index))
                    return 0;

                VstPinProperties* pp = cast(VstPinProperties*) ptr;
                pp.flags = kVstPinIsActive;

                if ( (index % 2) == 0 && index < _client.maxOutputs())
                    pp.flags |= kVstPinIsStereo;

                sprintf(pp.label.ptr, "Output %d", index);
                return 1;
            }

            case effGetPlugCategory: // opcode 35
                if ( _client.getFlags() & Client.IsSynth )
                    return kPlugCategSynth;
                else
                    return kPlugCategEffect;

            case DEPRECATED_effGetCurrentPosition: // opcode 36
            case DEPRECATED_effGetDestinationBuffer: // opcode 37
                return 0;

            case effOfflineNotify: // opcode 38
            case effOfflinePrepare: // opcode 39
            case effOfflineRun: // opcode 40
                return 0;

            case effProcessVarIo: // opcode 41
                return 0;

            case effSetSpeakerArrangement:
            {
                VstSpeakerArrangement* pInputArr = cast(VstSpeakerArrangement*) value;
                VstSpeakerArrangement* pOutputArr = cast(VstSpeakerArrangement*) ptr;
                if (pInputArr !is null && pOutputArr !is null )
                {
                    _usedInputs = pInputArr.numChannels;
                    _usedOutputs = pOutputArr.numChannels;

                    // limit to possible I/O
                    if (_usedInputs > _maxInputs)
                        _usedInputs = _maxInputs;
                    if (_usedOutputs > _maxOutputs)
                        _usedOutputs = _maxOutputs;

                    _messageQueue.pushBack(Message(Message.Type.changedIO,_usedInputs, _usedOutputs, 0.0f));

                    return 0;
                }
                return 1;
            }

            case effGetVendorString:
                {
                    char* p = cast(char*)ptr;
                    if (p !is null)
                    {
                        strcpy(p, "myVendor");
                    }
                    return 0;
                }

            case effGetProductString:
            {
                char* p = cast(char*)ptr;
                if (p !is null)
                {
                    strcpy(p, "lolg-plugin");
                }
                return 0;
            }

            case effCanDo:
            {
                char* str = cast(char*)ptr;
                if (str is null)
                    return 0;

                if (strcmp(str, "receiveVstTimeInfo") == 0)
                    return 1;

                if (_client.getFlags() & Client.IsSynth)
                {
                    if (strcmp(str, "sendVstEvents") == 0)
                        return 1;
                    if (strcmp(str, "sendVstMidiEvents") == 0)
                        return 1;
                    if (strcmp(str, "receiveVstEvents") == 0)
                        return 1;
                    if (strcmp(str, "receiveVstMidiEvents") == 0)
                        return 1;
                }
                return 0;
            }

            case effGetVstVersion:
                return 2400; // version 2.4

        default:
            return 0; // unknown opcode
        }
    }

    //
    // Processing buffers and callbacks
    //

    // Resize copy buffers according to maximum block size.
    void resizeScratchBuffers(int nFrames)
    {
        for (int i = 0; i < _maxInputs; ++i)
            _inputScratchBuffer[i].resize(nFrames);

        for (int i = 0; i < _maxOutputs; ++i)
            _outputScratchBuffer[i].resize(nFrames);
    }   

    void clearScratchBuffers(int nFrames)
    {
        for (int i = 0; i < _maxInputs; ++i)
            memset(_inputScratchBuffer[i].ptr, 0, nFrames * double.sizeof);
    }

    void beforeProcess()
    {
        Message msg;
        while(_messageQueue.popFront(msg))
        {
            final switch(msg.type)
            {
                case Message.Type.changedIO:
                {
                    bool success;
                    success = _client.setNumUsedInputs(msg.iParam);
                    assert(success);
                    success = _client.setNumUsedOutputs(msg.iParam2);
                    assert(success);
                    break;
                }

                case Message.Type.resetState:
                    resizeScratchBuffers(msg.iParam);
                    clearScratchBuffers(msg.iParam);
                    _client.reset(msg.fparam, msg.iParam);
                    break;
            }
        }
    }


    void process(float **inputs, float **outputs, int sampleFrames)
    {
        if (sampleFrames > _maxFrames)
            assert(false); // simply crash the audio thread if buffer is above the maximum size

        // existing inputs gets converted to double
        // non-connected input is zero
        for (int i = 0; i < _usedInputs; ++i)
        {
            float* source = inputs[i];
            double* dest = _inputScratchBuffer[i].ptr;
            for (int f = 0; f < sampleFrames; ++f)
                dest[f] = source[f];

            _inputPointers[i] = dest;
        }

        // TODO don't do this each time
        for (int i = _usedInputs; i < _maxInputs; ++i)
        {
            double* dest = _inputScratchBuffer[i].ptr;
            for (int f = 0; f < sampleFrames; ++f)
                dest[f] = 0;
            _inputPointers[i] = dest;
        }

        for (int i = 0; i < _maxOutputs; ++i)
        {
            _outputPointers[i] = _outputScratchBuffer[i].ptr;
        }

        beforeProcess();
        _client.processAudio(_inputPointers.ptr, _outputPointers.ptr, sampleFrames);

        for (int i = 0; i < _usedOutputs; ++i)
        {
            double* source = _outputScratchBuffer[i].ptr;
            float* dest = outputs[i];
            for (int f = 0; f < sampleFrames; ++f)
                dest[f] += cast(float)source[f];
        }
        // accumulate data back to float output
    }

    void processReplacing(float **inputs, float **outputs, int sampleFrames)
    {
        if (sampleFrames > _maxFrames)
            assert(false); // simply crash the audio thread if buffer is above the maximum size

        // fill output buffers with zeros
        for (int i = 0; i < _usedOutputs; ++i)
        {
            double* source = _outputScratchBuffer[i].ptr;
            float* dest = outputs[i];
            for (int f = 0; f < sampleFrames; ++f)
                dest[f] = 0;
        }
        process(inputs, outputs, sampleFrames);
    }

    void processDoubleReplacing(double **inputs, double **outputs, int sampleFrames)
    {        
        beforeProcess();
        _client.processAudio(inputs, outputs, sampleFrames);
    }

    
}

void unrecoverableError() nothrow
{
    debug
    {
        assert(false); // crash the Host in debug mode
    }
    else
    {
        // forget about the error since it doesn't seem a good idea
        // to crash in audio production
    }
}

// VST callbacks

extern(C) private nothrow
{
    VstIntPtr dispatcherCallback(AEffect *effect, int opcode, int index, int value, void *ptr, float opt) 
    {
        try
        {
            auto plugin = cast(VSTClient)(effect.user);
            return plugin.dispatcher(opcode, index, value, ptr, opt);
        }
        catch (Throwable e)
        {
            unrecoverableError(); // should not throw in a callback
        }
        return 0;
    }   

    void processCallback(AEffect *effect, float **inputs, float **outputs, int sampleFrames) 
    {
        try
        {
            auto plugin = cast(VSTClient)effect.user;
            plugin.process(inputs, outputs, sampleFrames);
        }
        catch (Throwable e)
        {
            unrecoverableError(); // should not throw in a callback
        }
    }

    void processReplacingCallback(AEffect *effect, float **inputs, float **outputs, int sampleFrames) 
    {
        try
        {
            auto plugin = cast(VSTClient)effect.user;
            plugin.processReplacing(inputs, outputs, sampleFrames);
        }
        catch (Throwable e)
        {
            unrecoverableError(); // should not throw in a callback
        }
    }

    void processDoubleReplacingCallback(AEffect *effect, double **inputs, double **outputs, int sampleFrames) 
    {
        try
        {
            auto plugin = cast(VSTClient)effect.user;
            plugin.processDoubleReplacing(inputs, outputs, sampleFrames);
        }
        catch (Throwable e)
        {
            unrecoverableError(); // should not throw in a callback
        }
    }

    void setParameterCallback(AEffect *effect, int index, float parameter)
    {
        try
        {
            auto plugin = cast(VSTClient)effect.user;
            Client client = plugin._client;

            if (!plugin.isValidParamIndex(index))
                return;

            return client.param(index).set(parameter);
        }
        catch (Throwable e)
        {
            unrecoverableError(); // should not throw in a callback
        }
    }

    float getParameterCallback(AEffect *effect, int index) 
    {
        try
        {
            auto plugin = cast(VSTClient)(effect.user);
            Client client = plugin._client;

            if (!plugin.isValidParamIndex(index))
                return 0.0f;

            return client.param(index).get();
        }
        catch (Throwable e)
        {
            unrecoverableError(); // should not throw in a callback

            // Still here? Return zero.
            return 0.0f;
        }
    }
}

// Copy source into dest.
// dest must contain room for maxChars characters
// A zero-byte character is then appended.
private void stringNCopy(char* dest, size_t maxChars, string source)
{
    if (maxChars == 0)
        return;

    size_t max = maxChars < source.length ? maxChars - 1 : source.length;
    for (int i = 0; i < max; ++i)
        dest[i] = source[i];
    dest[max] = '\0';
}



///
///
///          Access to VST host from client perspective.
///
///
struct VSTHostFromClientPOV
{
public:

    void init(HostCallbackFunction hostCallback, AEffect* effect)
    {
        _hostCallback = hostCallback;
        _effect = effect;
        _daw = identifyDAW(productString());
    }

    /**
     * Returns:
     * 	  Input latency in frames.
     */
    int inputLatency() nothrow 
    {
        return cast(int)_hostCallback(_effect, audioMasterGetInputLatency, 0, 0, null, 0);
    }

    /**
     * Returns:
     * 	  Output latency in frames.
     */
    int outputLatency() nothrow 
    {
        return cast(int)_hostCallback(_effect, audioMasterGetOutputLatency, 0, 0, null, 0);
    }

    /**
     * Deprecated: This call is deprecated, but was added to support older hosts (like MaxMSP).
     * Plugins (VSTi2.0 thru VSTi2.3) call this to tell the host that the plugin is an instrument.
     */
    void wantEvents() nothrow
    {
        _hostCallback(_effect, DEPRECATED_audioMasterWantMidi, 0, 1, null, 0);
    }

    /**
     * Returns:
     *    Current sampling rate of host.
     */
    float samplingRate() nothrow
    {
        float *f = cast(float *) _hostCallback(_effect, audioMasterGetSampleRate, 0, 0, null, 0);
        return *f;
    }

    /**
    * Returns:
    *    current block size of host.
    */
    int blockSize() nothrow
    {
        return cast(int)_hostCallback(_effect, audioMasterGetBlockSize, 0, 0, null, 0.0f);
    }

    /// Request plugin window resize.
    bool requestResize(int width, int height) nothrow
    {
        return (_hostCallback(_effect, audioMasterSizeWindow, width, height, null, 0.0f) != 0);
    }

    const(char)* vendorString() nothrow
    {
        int res = cast(int)_hostCallback(_effect, audioMasterGetVendorString, 0, 0, _vendorStringBuf.ptr, 0.0f);
        if (res == 1)
        {
            //size_t len = strlen(_vendorStringBuf.ptr);
            return _vendorStringBuf.ptr;
        }
        else
            return "unknown";
    }

    const(char)* productString() nothrow
    {
        int res = cast(int)_hostCallback(_effect, audioMasterGetProductString, 0, 0, _productStringBuf.ptr, 0.0f);
        if (res == 1)
        {
            return _productStringBuf.ptr;
        }
        else
            return "unknown";
    }

    /// Capabilities

    enum HostCaps
    {
        SEND_VST_EVENTS,                      // Host supports send of Vst events to plug-in.
        SEND_VST_MIDI_EVENTS,                 // Host supports send of MIDI events to plug-in.
        SEND_VST_TIME_INFO,                   // Host supports send of VstTimeInfo to plug-in.
        RECEIVE_VST_EVENTS,                   // Host can receive Vst events from plug-in.
        RECEIVE_VST_MIDI_EVENTS,              // Host can receive MIDI events from plug-in.
        REPORT_CONNECTION_CHANGES,            // Host will indicates the plug-in when something change in plug-in´s routing/connections with suspend()/resume()/setSpeakerArrangement().
        ACCEPT_IO_CHANGES,                    // Host supports ioChanged().
        SIZE_WINDOW,                          // used by VSTGUI
        OFFLINE,                              // Host supports offline feature.
        OPEN_FILE_SELECTOR,                   // Host supports function openFileSelector().
        CLOSE_FILE_SELECTOR,                  // Host supports function closeFileSelector().
        START_STOP_PROCESS,                   // Host supports functions startProcess() and stopProcess().
        SHELL_CATEGORY,                       // 'shell' handling via uniqueID. If supported by the Host and the Plug-in has the category kPlugCategShell
        SEND_VST_MIDI_EVENT_FLAG_IS_REALTIME, // Host supports flags for VstMidiEvent.
        SUPPLY_IDLE                           // ???
    }

    bool canDo(HostCaps caps) nothrow
    {
        const(char)* capsString = hostCapsString(caps);
        assert(capsString !is null);

        // note: const is casted away here
        return _hostCallback(_effect, audioMasterCanDo, 0, 0, cast(void*)capsString, 0.0f) == 1;
    }


private:
    AEffect* _effect;
    HostCallbackFunction _hostCallback;
    char[65] _vendorStringBuf;
    char[96] _productStringBuf;
    int _vendorVersion;
    DAW _daw;

    static const(char)* hostCapsString(HostCaps caps) pure nothrow
    {
        switch (caps)
        {
            case HostCaps.SEND_VST_EVENTS: return "sendVstEvents";
            case HostCaps.SEND_VST_MIDI_EVENTS: return "sendVstMidiEvent";
            case HostCaps.SEND_VST_TIME_INFO: return "sendVstTimeInfo";
            case HostCaps.RECEIVE_VST_EVENTS: return "receiveVstEvents";
            case HostCaps.RECEIVE_VST_MIDI_EVENTS: return "receiveVstMidiEvent";
            case HostCaps.REPORT_CONNECTION_CHANGES: return "reportConnectionChanges";
            case HostCaps.ACCEPT_IO_CHANGES: return "acceptIOChanges";
            case HostCaps.SIZE_WINDOW: return "sizeWindow";
            case HostCaps.OFFLINE: return "offline";
            case HostCaps.OPEN_FILE_SELECTOR: return "openFileSelector";
            case HostCaps.CLOSE_FILE_SELECTOR: return "closeFileSelector";
            case HostCaps.START_STOP_PROCESS: return "startStopProcess";
            case HostCaps.SHELL_CATEGORY: return "shellCategory";
            case HostCaps.SEND_VST_MIDI_EVENT_FLAG_IS_REALTIME: return "sendVstMidiEventFlagIsRealtime";
            case HostCaps.SUPPLY_IDLE: return "supplyIdle";
            default:
                assert(false);
        }
    }
}

private
{
    struct Message
    {
        enum Type
        {
            resetState, // reset plugin state, set samplerate and buffer size (samplerate = fParam, buffersize in frames = iParam)
            changedIO,  // number of inputs/outputs changes (num. inputs = iParam, num. outputs = iParam2)
        }

        Type type;
        int iParam;
        int iParam2;
        float fparam;
    }
}
