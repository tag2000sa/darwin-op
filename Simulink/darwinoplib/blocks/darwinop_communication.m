function darwinop_communication(block)
setup(block);

end

function setup(block)

% Register original number of ports based on settings in Mask Dialog
values = get_param(block.BlockHandle,'MaskValues');

% see mask properties
% values{1} = IP
% values{2} = Port
% values{3} = Protocol
% values{4} = Timeout
% values{5} = Frame
% values{6} = ReadIndex
% values{7} = WriteIndex

block.NumInputPorts = size(eval(values{7}),1);
block.NumOutputPorts = size(eval(values{6}),1);

% Setup port properties to be inherited or dynamic
block.SetPreCompInpPortInfoToDynamic;
block.SetPreCompOutPortInfoToDynamic;

% Override input port properties
for i = 1:block.NumInputPorts
    block.InputPort(i).DatatypeID  = 0;  % double
    block.InputPort(i).Complexity  = 'Real';
    block.InputPort(i).SamplingMode = 'Sample'; % sample based
end

% Override output port properties
for i = 1:block.NumOutputPorts
    block.OutputPort(i).DatatypeID  = 0; % double
    block.OutputPort(i).Complexity  = 'Real';
    block.OutputPort(i).SamplingMode = 'Sample'; % sample based
end

block.NumDialogPrms     = 7;
block.DialogPrmsTunable = {'Nontunable','Nontunable','Nontunable','Nontunable','Nontunable','Nontunable','Nontunable'};

% Register inherited discrete sample time [-1 offset]
block.SampleTimes = [-1 0];

% No parallel queries
block.SupportsMultipleExecInstances(false);

% Specify if Accelerator should use TLC or call back into
% M-file
block.SetAccelRunOnTLC(false);

block.RegBlockMethod('CheckParameters',          @CheckPrms);
block.RegBlockMethod('ProcessParameters',        @ProcessPrms);
block.RegBlockMethod('Start',                    @Start);
block.RegBlockMethod('PostPropagationSetup',     @DoPostPropagationSetup);
block.RegBlockMethod('SetInputPortSamplingMode', @SetInputPortSamplingMode);
block.RegBlockMethod('Outputs',                  @Outputs);
block.RegBlockMethod('Terminate',                @Terminate);
block.RegBlockMethod('WriteRTW',                 @WriteRTW);

end

function CheckPrms(block)

%IP = block.DialogPrm(1).Data;
Port  = block.DialogPrm(2).Data;
Protocol  = block.DialogPrm(3).Data;
Timeout   = block.DialogPrm(4).Data;
Frame   = block.DialogPrm(5).Data;
ReadIndex   = block.DialogPrm(6).Data;
WriteIndex   = block.DialogPrm(7).Data;

% TODO checks
if (Port <= 0) || (Port > 65535)
    error('incorrect port number, it should be in range [1..65535]');
end

if (Protocol ~= 1) && (Protocol ~= 2)
    error('invalid communication protocol');
end

if ~isreal(Timeout) || ~isfloat(Timeout) || (length(Timeout) ~= 1)
    error('invalid timeout, it should be a floating point scalar');
end

if ~isreal(Frame) || ~isfloat(Frame)
    error('invalid frame, it should be a floating point vector');
end

if ~isreal(ReadIndex) || ~isfloat(ReadIndex) || (size(ReadIndex,2) ~= 2)
    error('invalid read index, it should be a floating point matrix');
end

if ~isreal(WriteIndex) || ~isfloat(WriteIndex) || (size(WriteIndex,2) ~= 2)
    error('invalid read index, it should be a floating point matrix');
end

end

function ProcessPrms(block)

%% Update run time parameters
block.AutoUpdateRuntimePrms;

end

function DoPostPropagationSetup(block)

% Register all tunable parameters as runtime parameters.
block.AutoRegRuntimePrms;

% 1 internal state for holding tcp/udp object
block.NumDWorks = 1;
% 1 = tcp/udp object
block.Dwork(1).Usage = 'DState';
block.Dwork(1).UsedAsDiscState = true;
block.Dwork(1).Dimensions = 1;
block.Dwork(1).DatatypeID = 0; % double
block.Dwork(1).Complexity = 'real';
block.Dwork(1).Name = 'NetObj';

end

function Start(block)

if strcmp(get_param(gcs,'RTWCGKeepContext'),'on')
    disp('### Detecting a RTW build');
    % do not start the simulation locally
    % why is this function called when the RTW model is being built?
    return;
else
    disp('### Detecting a normal simulation');
end

IP = block.DialogPrm(1).Data;
Port  = block.DialogPrm(2).Data;
Protocol  = block.DialogPrm(3).Data;
Timeout   = block.DialogPrm(4).Data;
Frame   = block.DialogPrm(5).Data;
ReadIndex   = block.DialogPrm(6).Data;
%WriteIndex   = block.DialogPrm(7).Data;

InputBufferSize = max(sum(ReadIndex,2)) - 1;

if Protocol == 1
    NetObj = tcpip(IP, Port);
else
    NetObj = udp(IP, Port);
end
NetObj.Timeout = Timeout;
NetObj.InputBufferSize = InputBufferSize;
NetObj.OutputBufferSize = length(Frame);

try
    fopen(NetObj);
catch
    error('network communication error: failed to open the communication');
end

global NetObjects;
if isempty(NetObjects)
    NetObjects = [NetObj]; %#ok
    block.Dwork(1).Data = 1;
else
    for i = 1:length(NetObjects)
        if strcmp(NetObjects(i).Status,'closed')
            NetObjects(i) = NetObj;
            block.Dwork(1).Data = i;
            return;
        end
    end
    NetObjects = [NetObjects NetObj];
    block.Dwork(1).Data = length(NetObjects);
end

end

function SetInputPortSamplingMode(block, idx, mode)
block.InputPort(idx).SamplingMode = mode;

for i = 1:block.NumOutputPorts
    block.OutputPort(i).SamplingMode = 'Sample';
end

end

function Outputs(block)

Frame = block.DialogPrm(5).Data;
ReadIndex = block.DialogPrm(6).Data;
WriteIndex = block.DialogPrm(7).Data;

global NetObjects;
NetObj = NetObjects(block.Dwork(1).Data);

for i=1:size(WriteIndex,1)
    if WriteIndex(i,2) == 1
        val = uint8(block.InputPort(i).Data);
        Frame(WriteIndex(i,1)) = val;
    else
        j = WriteIndex(i,1);
        val = uint16(block.InputPort(i).Data);
        Frame(j) = bitand(val,255);
        Frame(j + 1) = bitand(val,65280) / 256;
    end
end

try
    fwrite(NetObj,uint8(Frame)); %(1:NetObj.InputBufferSize)));
    Data = fread(NetObj);
catch
    error('network communication error: write/read failure');
end

if length(Data) ~= NetObj.InputBufferSize
    error('network communication error: insufficient bytes are returned (%d of %d)',length(Data),NetObj.InputBufferSize);
end

for i=1:size(ReadIndex,1)
    if ReadIndex(i,2) == 1
        block.OutputPort(i).Data = double(Data(ReadIndex(i,1)));
    else
        j = ReadIndex(i,1);
        block.OutputPort(i).Data = double(Data(j)) + 256*double(Data(j + 1));
    end
end

NetObjects(block.Dwork(1).Data) = NetObj;

end

function Terminate(block)
    global NetObjects;
    if block.Dwork(1).Data > 0
        NetObj = NetObjects(block.Dwork(1).Data);
        try
            fclose(NetObj);
        catch
            error('network communication error: failed to close the communication');
        end
        NetObjects(block.Dwork(1).Data) = NetObj;
    end
end

function WriteRTW(block)

    %IP = block.DialogPrm(1).Data;
    %Port  = block.DialogPrm(2).Data;
    %Protocol  = block.DialogPrm(3).Data;
    %Timeout   = block.DialogPrm(4).Data;
    Frame   = block.DialogPrm(5).Data;
    ReadIndex   = block.DialogPrm(6).Data;
    WriteIndex   = block.DialogPrm(7).Data;

    % first pass to get number of bus operations
    OperationCount = 0;
    i=1;
    while (i<=length(Frame))
        if Frame(i) == 2
            i = i+4;
        else
            i = i+4+Frame(i+3);
        end
        OperationCount = OperationCount + 1;
    end
    OperationKind = zeros(1,OperationCount);
    OperationID = zeros(1,OperationCount);
    OperationAddress = zeros(1,OperationCount);
    OperationSize = zeros(1,OperationCount);
    InputCount = size(WriteIndex,1);
    InputOperationIndex = zeros(1,InputCount);
    InputOperationAddress = zeros(1,InputCount);
    InputOperationSize = zeros(1,InputCount);
    OutputCount = size(ReadIndex,1);
    OutputOperationIndex = zeros(1,OutputCount);
    OutputOperationAddress = zeros(1,OutputCount);
    OutputOperationSize = zeros(1,OutputCount);

    i=1;
    OperationIndex = 1;
    InputIndex = 1;
    OutputIndex = 1;
    ReadLen = 0;
    while (i<=length(Frame))
        Kind = Frame(i);
        OperationKind(OperationIndex) = Kind;
        ID = Frame(i+1);
        OperationID(OperationIndex) = ID;
        Addr = Frame(i+2);
        OperationAddress(OperationIndex) = Addr;
        Len = Frame(i+3);
        OperationSize(OperationIndex) = Len;
        if Kind == 2
            % read operation
            for j=1:size(ReadIndex,1)
                if ((ReadIndex(j,1) - 1)>= ReadLen) && ...
                   ((ReadIndex(j,1) - 1 + ReadIndex(j,2)) <= (ReadLen + Len))
                    OutputOperationIndex(OutputIndex) = OperationIndex-1;
                    OutputOperationAddress(OutputIndex) = Addr + ReadIndex(j,1) - 1 - ReadLen;
                    OutputOperationSize(OutputIndex) = ReadIndex(j,2);
                    OutputIndex = OutputIndex+1;
                end
            end
            ReadLen = ReadLen + Len;
            % skip the header bytes
            i = i+4;
        else
            % write operation
            for j=1:size(WriteIndex,1)
                if (WriteIndex(j,1) >= (i+4)) && ...
                   ((WriteIndex(j,1) + WriteIndex(j,2)) <= (i+4+Len))
                    InputOperationIndex(InputIndex) = OperationIndex-1;
                    InputOperationAddress(InputIndex) = Addr + WriteIndex(j,1) - (i+4);
                    InputOperationSize(InputIndex) = WriteIndex(j,2);
                    InputIndex = InputIndex+1;
                end
            end
            % skip the header and data bytes
            i = i+4+Len;
        end
        OperationIndex = OperationIndex+1;
    end

    block.WriteRTWParam('matrix', 'OperationCount', int32(length(OperationKind)));
    block.WriteRTWParam('matrix', 'OperationKind', int32(OperationKind));
    block.WriteRTWParam('matrix', 'OperationID', int32(OperationID));
    block.WriteRTWParam('matrix', 'OperationAddress', int32(OperationAddress));
    block.WriteRTWParam('matrix', 'OperationSize', int32(OperationSize));

    block.WriteRTWParam('matrix', 'InputCount', int32(length(InputOperationIndex)));
    block.WriteRTWParam('matrix', 'InputOperationIndex', int32(InputOperationIndex));
    block.WriteRTWParam('matrix', 'InputOperationAddress', int32(InputOperationAddress));
    block.WriteRTWParam('matrix', 'InputOperationSize', int32(InputOperationSize));

    block.WriteRTWParam('matrix', 'OutputCount', int32(length(OutputOperationIndex)));
    block.WriteRTWParam('matrix', 'OutputOperationIndex', int32(OutputOperationIndex));
    block.WriteRTWParam('matrix', 'OutputOperationAddress', int32(OutputOperationAddress));
    block.WriteRTWParam('matrix', 'OutputOperationSize', int32(OutputOperationSize));

end
