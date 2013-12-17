function [xOut, fsOut, p] = vocode(xIn, fsIn, params)

% [Xout, FSout] = VOCODE(Xin, FSin, PARAMS)
%   Band-vocode Xin using details provided in PARAMS
%
%   PARAMS must contain a field 'analysis_filters' of the form:
%       analysis_filters.filterA
%       analysis_filters.filterB
%       analysis_filters.center
%       analysis_filters.lower
%       analysis_filters.upper
%   Such structure can be produced by FILTER_BANDS.
%
%   PARAMS can also contain a field 'synthesis_filters' of the same form.
%   If no such field is provided, the content of 'analysis_filters' will be
%   used. If provided, its elements must of the same length as those of
%   'analysis_filters'.
%
%   The field 'envelope' contains a structure describing how the envelope
%   should be calculated with the following fields:
%       method = 'low-pass' (default) or 'hilbert'
%   If method is 'low-pass', the following fields should be also provided:
%       rectify = 'half-wave' (default) or 'full-wave'
%       fc      = cuttof frequency in Hz (250 Hz default)
%       order   = the order of the filter, the actual order will be
%                 multiplied by 4 (default is 2, hence filters of effective
%                 order 8)
%
%   The field 'synth' describes how the resynthesis should be performed:
%       carrier = 'noise' (default), 'sin', 'low-noise' or 'pshc'
%   For the noise carrier, the bands of noise can be filtered before
%   modulation by the envelope by specifying:
%       filter_before = true (default is false)
%   For all carriers, the modulated carrier can be refiltered in the band
%   to suppress sidebands by specifying:
%       filter_after  = true (default)
%   For 'pshc', the field 'f0' must also be provided (no default).
%
%   For 'noise', 'low-noise' and 'pshc' carriers, the random stream will be
%   initialized using the field PARAMS.random_seed. By default this field
%   contains sum(100*clock).
%
%   See also FILTER_BANDS, GET_LOWNOISE, GET_PSHC
 

% Etienne Gaudrain <etienne.gaudrain@mrc-cbu.cam.ac.uk> - 2010-02-17
% MRC Cognition and Brain Sciences Unit, Cambridge, UK

% Etienne Gaudrain <e.p.c.gaudrain@umcg.nl> - 2013-09-11
% KNO, University Medical Center Groningen, NL

% Copyright UMCG, Etienne Gaudrain, 2013
% This is code is distributed with no warranty under GNU General Public
% License v3.0. See http://www.gnu.org/licenses/gpl-3.0.txt for the full
% text.

p = default_parameters(params);

fs = fsIn;

%--------------------- Compute de output RMS
% We filter between the lower and upper freqs of the analysis filters so
% the RMS of the output corresponds to the RMS of this portion of the
% spectrum of the input.

[b, a] = butter(min(p.analysis_filters.order([1, end])), [p.analysis_filters.lower(1), p.analysis_filters.upper(end)]*2/fs);
rmsOut = rms(filtfilt(b, a, xIn));

%--------------------- Prepare the band filters
AF = p.analysis_filters;
SF = p.synthesis_filters;

if length(AF.center)~=length(SF.center)
    error('Vocode:analysis_synthesis_mismatch', 'There should be as many analysis filters as synthesis filters.')
else
    nCh = length(AF.center);
end

%--------------------- Prepare the envelope filters
switch p.envelope.method
    case {'low-pass', 'lp', 'low'}
        if length(p.envelope.fc)==1
            p.envelope.fc = ones(nCh,1)*p.envelope.fc(1);
        end
        if length(p.envelope.fc)~=nCh
            error('Vocode:n_envelope_fc', 'params.envelope.fc [%d] must be of length the number of channels [%d]', length(p.envelope.fc), nCh);
        end
        
        if length(p.envelope.order)==1
            p.envelope.order = ones(nCh,1)*p.envelope.order(1);
        end
        if length(p.envelope.order)~=nCh
            error('Vocode:n_envelope_fc', 'params.envelope.order [%d] must be of length the number of channels [%d]', length(p.envelope.order), nCh);
        end
        
        for i=1:nCh
            [blo,alo] = butter(p.envelope.order(i), p.envelope.fc(i)*2/fs, 'low');
            p.envelope.filter(i).b = blo;
            p.envelope.filter(i).a = alo;
        end
            
    case 'hilbert'
    otherwise
        error('Vocode:envelope_method_unknown', 'Method "%s" is unknown for the envelope parameter', p.envelope.method);
end

%--------------------- Some initialisation

nSmp = length(xIn);
ModC = zeros(nSmp, nCh);
%{
y    = zeros(nSmp, 1);
env  = zeros(nSmp, 1);
nz   = zeros(nSmp, 1);
%}
%cmpl = zeros(nSmp, 1);

% RMS levels of original filter-bank outputs are stored in the vector 'levels'
levels = zeros(nCh, 1);

%--------------------- Synthesize each channel

for i=1:nCh
    %y=filter(AF.filterB(i,:), AF.filterA(i,:),x)';
    y = filtfilt(AF.filterB(i,:), AF.filterA(i,:), xIn);
    levels(i) = rms(y);
    
    switch p.envelope.method
        case 'hilbert'
            env = abs(hilbert(y));
            
        case {'low-pass', 'lp', 'low'}
            
            switch p.envelope.rectify
                case {'half', 'half-wave'}
                    env = max(y, 0);
                case {'full', 'full-wave'}
                    env = abs(y);
                otherwise
                    error('Vocode:envelope_rectify_unknown', 'Rectification "%s" is unknown.', p.envelope.rectify);
            end
            
            env = max(filtfilt(p.envelope.filter(i).b, p.envelope.filter(i).a, env), 0);
  
    end
    
    env = env / max(env);

    switch p.synth.carrier
        case 'noise'
            %-- Excite with noise
            rng(p.random_seed);
            nz = sign(rand(nSmp,1)-0.5);
            if p.synth.filter_before
                nz = filtfilt(SF.filterB(i,:), SF.filterA(i,:), nz);
            end
            
        case {'sine', 'sin'}
            %-- Sinewave
            nz = sin(SF.center(i)*2.0*pi*(0:(nSmp-1))'/fs);
            
        case {'low-noise', 'low-noise-noise', 'lnn'}
            %-- Low-noise-noise
            nz = get_lownoise(nSmp, fs, SF.lower(i), SF.upper(i), p.random_seed);
            
        case {'pshc'}
            nz = get_pshc(nSmp, fs, SF.lower(i), SF.upper(i), p.synth.f0, p.random_seed);
        
    end
    
    ModC(:,i) = env .* nz;
    
    if p.synth.filter_after
        ModC(:,i) = filtfilt(SF.filterB(i,:), SF.filterA(i,:), ModC(:,i));
    end
    
    % Restore the RMS of the channel
    ModC(:,i) = ModC(:,i) / rms(ModC(:,i)) * levels(i);
end

%--------------------- Reconstruct

xOut = sum(ModC, 2);
xOut = xOut / rms(xOut) * rmsOut;

% CAREFUL: the output is not scaled to avoid clipping

%{
max_sample = max(abs(xOut));
if max_sample > (2^15-2)/2^15
    % figure out degree of attenuation necessary
    ratio = 1.0/max_sample;
    wave=wave * ratio;
    warning(sprintf('Sound scaled by %f = %f dB\n', ratio, 20*log10(ratio)));
end

xOut = wave';
%}

fsOut = fsIn;

%==========================================================================
function p = default_parameters(params)
% Fill the structure with default parameters, merges with the provided
% params, and check them

p = struct();

%-- Envelope extraction
p.envelope = struct();
p.envelope.method = 'low-pass';
p.envelope.rectify = 'half-wave';
p.envelope.fc = 250;
p.envelope.order = 2;

%-- Synthesis
p.synth = struct();
p.synth.carrier = 'noise';
p.synth.filter_before = false; % Filter the carrier before modulation
p.synth.filter_after  = true;  % Filter the carrier after modulation
p.synth.f0 = .3;

%-- Other params
p.display = false;
p.random_seed = sum(100*clock);

%----------

p = merge_structs(p, params);

if ~isfield(p, 'analysis_filters')
    error('Vocode:analysis_filters', 'The field "analysis_filters" is mandatory and was not provided in the parameters.');
end

if ~isfield(p, 'synthesis_filters')
    p.synthesis_filters = p.analysis_filters;
    warning('Vocode:synthesis_filters', 'The analysis filters will be used for synthesis.');
end

%==========================================================================
function c = merge_structs(a, b)
% A is the default, and we update with the values of B

c = a;

keys = fieldnames(b);

for k = 1:length(keys)
    
    key = keys{k};
    
    if isstruct(b.(key)) && isfield(a, key)
        c.(key) = merge_structs(a.(key), b.(key));
    else
        c.(key) = b.(key);
    end
    
end