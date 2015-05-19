% --------------------------------------------------------------------------
% TS_compute
% --------------------------------------------------------------------------
% 
% This function fills in the missing elements of TS_DataMat, from HCTSA_loc.mat
% (retrieved from the database using SQL_retrieve).
% The function systematically calculates these missing elements (in parallel
% over operations for each time series if specified).
% 
%---INPUTS:
% doLog:      if 1 (0 by default) writes to a log file.
% doParallel: if 1, attempts to use the Parallel Computing Toolbox to run
%             computations in parallel over multiple cores.
% beVocal:    if 1, gives additional user feedback.
% 
%---OUTPUTS:
% Writes output into HCTSA_loc.mat
%
% ------------------------------------------------------------------------------
% Copyright (C) 2015, Ben D. Fulcher <ben.d.fulcher@gmail.com>,
% <http://www.benfulcher.com>
% 
% If you use this code for your research, please cite:
% B. D. Fulcher, M. A. Little, N. S. Jones, "Highly comparative time-series
% analysis: the empirical structure of time series and their methods",
% J. Roy. Soc. Interface 10(83) 20130048 (2010). DOI: 10.1098/rsif.2013.0048
% 
% This work is licensed under the Creative Commons
% Attribution-NonCommercial-ShareAlike 4.0 International License. To view a copy of
% this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send
% a letter to Creative Commons, 444 Castro Street, Suite 900, Mountain View,
% California, 94041, USA.
% ------------------------------------------------------------------------------

function TS_compute(doParallel,ts_id_range,op_id_range,doLog,beVocal)
    
% --------------------------------------------------------------------------
%% Check inputs and set defaults
% --------------------------------------------------------------------------

% Use Matlab's Parallel Computing toolbox?
if nargin < 1
	doParallel = 0;
end

if nargin < 2
    ts_id_range = []; % compute all ts_ids in the file by default
end
if nargin < 3
    op_id_range = []; % compute all op_ids in the file by default
end

% Log to file
if nargin < 4
    % By default, do not log to file, write to screen (if beVocal)
	doLog = 0;
end
if doLog
	fn = sprintf('HCTSA_brawn_%s.log',datestr(now,30));
	fid = fopen(fn,'w','n');
	fprintf(1,'Calculation details will be logged to %s\n',fn);
else
    % Write output to screen rather than .log file
    fid = 1;
end

% Be vocal?
if nargin < 5
    beVocal = 1; % Write back lots of information to screen
    % prints every piece of code evaluated (nice for error checking)
end


% Start the log by telling the user about how the computation will be performed:
if doParallel
    fprintf(fid,['Computation will be performed across multiple cores' ...
            ' using Matlab''s Parallel Computing Toolbox.\n'])
else % use single-threaded for loops
	fprintf(fid,'Computations will be performed serially without parallelization.\n')
end


% --------------------------------------------------------------------------
%% Load information from local files
% --------------------------------------------------------------------------
fprintf(fid,'Loading data from HCTSA_loc.mat...');
load('HCTSA_loc.mat')
fprintf(fid,' Loaded.\n');

% ------------------------------------------------------------------------------
% Get indices if computing a subset
% ------------------------------------------------------------------------------
allIDs = [TimeSeries.ID];
if isempty(ts_id_range)
    ts_id_range = allIDs;
    tsIndex = 1:length(TimeSeries);
else
    ts_id_range = intersect(ts_id_range,allIDs);
    tsIndex = find(ismember(allIDs,ts_id_range));
    % tsIndex = arrayfun(@(x)find(allIDs==x,1),ts_id_range);
end
allIDs = [Operations.ID];
if isempty(op_id_range)
    op_id_range = allIDs;
    opCompute = ones(1,length(Operations));
else
    op_id_range = intersect(op_id_range,allIDs);
    opCompute = ismember(allIDs,op_id_range);
end

% Definitions
numTimeSeries = length(ts_id_range); % Number of time series
numOps = length(op_id_range); % Number of operations

fprintf(fid,['Calculation has begun on %s using %u datasets ' ...
                            'and %u operations\n'],datestr(now),numTimeSeries,numOps);

% ------------------------------------------------------------------------------
%% Open parallel processing worker pool
% ------------------------------------------------------------------------------
if doParallel
    % first check that the user can use the Parallel Computing Toolbox:
    heyLo = which('matlabpool');
    if isempty(heyLo)
        fprintf(1,['Parallel Computing Toolbox not found -- ' ...
                        'cannot perform computations across multiple cores\n'])
        doParallel = 0;
    else
        if (matlabpool('size') == 0)
        	matlabpool open;
            fprintf(fid,['Matlab parallel processing pool opened with %u ' ...
                                    'and ready to go'],matlabpool('size'))
        else
            fprintf(fid,['Matlab parallel processing pool already open. ' ...
                                        'Size: %u\n'],matlabpool('size'))
        end
    end
end


% Times stores the time taken for each time series to have its operations
% calculated (for determining time remaining)
times = zeros(numTimeSeries,1); 
lastSavedTime = 0; % Last saved time

% --------------------------------------------------------------------------
%% Computation
% --------------------------------------------------------------------------
for i = 1:numTimeSeries
    tsInd = tsIndex(i);
    
	bigTimer = tic;

    % ----
    % Which operations need calculating for this time series?:
    % ----
	qq = TS_Quality(tsInd,:); % The calculation states of any existing results for the current time series, a line of TS_Quality
					   	  % NaN indicates a value never before calculated, 1 indicates fatal error before (try again now)
    toCalc = (opCompute & isnan(qq) | qq == 1); % Operations awaiting calculation
    numCalc = sum(toCalc); % Number of operations to evaluate
    
    % -----
    % Check that all operations have a master ID attached:
    % -----
    if length([Operations(toCalc).MasterID]) < numCalc
        % Error in the database structure; some operations are missing MasterID assignment
        error('Database structure error: some operations have not been assigned a valid master operation');
    end
    
    
    if numCalc > 0 % some to calculate
        ffi = zeros(numCalc,1); % Output of each operation
		qqi = zeros(numCalc,1); % Quality of output from each operation
		cti = ones(numCalc,1)*NaN; % Calculation time for each operation
        
        % Load the time-series data as x
        x = TimeSeries(tsInd).Data;
        
        % --------------------------------------------------------------------------
		%% Basic checking on x
        % --------------------------------------------------------------------------
		% Univariate and [N x 1]
		if size(x,2) ~= 1
			if size(x,1) == 1
                fprintf(fid,['***** The time series %s is a row vector. Not sure how it snuck through the cracks, but I ' ...
                                        'need a column vector...\n'],TimeSeries(tsInd).Name);
				fprintf(fid,'I''ll transpose it for you for now....\n');
				x = x';
			else
				fprintf(fid,'******************************************************************************************\n')
                fprintf(fid,['MASSIVE ERROR WITH THIS TIME SERIES!!!: %s -- is it multivariate or something weird???.' ...
                                                                    ' Skipping it!!\n'], TimeSeries(tsInd).Name);
				fprintf(fid,'******************************************************************************************\n');
				continue % skip to the next time series; the entries for this time series in TS_DataMat etc. will remain NaNs
            end
		end

        % --------------------------------------------------------------------------
        %% Pre-Processing
        % --------------------------------------------------------------------------
		% y is a z-scored transformation of the time series
        % z-score without using a Statistics Toolbox license (i.e., the 'zscore' function):
		y = BF_zscore(x);

		% So we now have the raw time series x and the z-scored time series y.
		% Operations take these as inputs.

        % --------------------------------------------------------------------------
		%% Display information
        % --------------------------------------------------------------------------
		fprintf(fid,'\n\n=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\n')
	    fprintf(fid,'; ; ; : : : : ; ; ;    %s     ; ; ; : : : ; ; ;\n',datestr(now))
	    fprintf(fid,'- - - - - - - - - - - Loaded time series %u / %u - - - - - - - - - - -\n',i,numTimeSeries)
		fprintf(fid,'=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\n')
		fprintf(fid,'Preparing to calculate %s\nts_id = %u, N = %u samples\nComputing %u / %u operations.\n', ...
                            		TimeSeries(tsInd).Name,TimeSeries(tsInd).ID,TimeSeries(tsInd).Length,numCalc,numOps)
	    fprintf(fid,'=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\n\n')

        % --------------------------------------------------------------------------
		%% Evaluate all master operation functions (maybe in parallel)
        % --------------------------------------------------------------------------
		% Because of parallelization, we have to evaluate all the master functions *first*
		% Check through the metrics to determine which master functions are relevant for this run

		% Put the output from each Master operation in an element of MasterOutput
		MasterOutput = cell(length(MasterOperations),1); % Ouput structures
		MasterCalcTime = zeros(length(MasterOperations),1); % Calculation times for each master operation
		
		Master_IDs_calc = unique([Operations(toCalc).MasterID]); % Master_IDs that need to be calculated
        Master_ind_calc = arrayfun(@(x)find([MasterOperations.ID]==x,1),Master_IDs_calc); % Indicies of MasterOperations that need to be calculated
		numMopsToCalc = length(Master_IDs_calc); % Number of master operations to calculate
        
        % Index sliced variables to minimize the communication overhead in the parallel processing
        par_MasterOpCodeCalc = {MasterOperations(Master_ind_calc).Code}; % Cell array of strings of Code to evaluate
        par_mop_ids = [MasterOperations(Master_ind_calc).ID]; % mop_id for each master operation
        % par_mop_id = [Operations(toCalc).MasterID]; % Master_IDs corresponding to each Operation
        
		fprintf(fid,'Evaluating %u master operations...\n',length(Master_IDs_calc));
		
	    % Store in temporary variables for parfor loop then map back later
        MasterOutput_tmp = cell(numMopsToCalc,1);
        MasterCalcTime_tmp = zeros(numMopsToCalc,1);
		
        % ----
		% Evaluate all the master operations
        % ----
        TimeSeries_i_ID = TimeSeries(tsInd).ID; % Make a PARFOR-friendly version of the ID
        masterTimer = tic;
		if doParallel
            parfor jj = 1:numMopsToCalc % PARFOR Loop
                [MasterOutput_tmp{jj}, MasterCalcTime_tmp(jj)] = ...
                            TS_compute_masterloop(x,y,par_MasterOpCodeCalc{jj}, ...
                                        par_mop_ids(jj),numMopsToCalc,fid,beVocal,TimeSeries_i_ID,jj);
            end
        else
            for jj = 1:numMopsToCalc % Normal FOR Loop
                [MasterOutput_tmp{jj}, MasterCalcTime_tmp(jj)] = ...
                            TS_compute_masterloop(x,y,par_MasterOpCodeCalc{jj}, ...
                                        par_mop_ids(jj),numMopsToCalc,fid,beVocal,TimeSeries_i_ID,jj);
            end
		end
		
        % Map back from temporary versions to the full versions
        MasterOutput(Master_ind_calc) = MasterOutput_tmp;
        MasterCalcTime(Master_ind_calc) = MasterCalcTime_tmp;
		
		fprintf(fid,'%u master operations evaluated in %s ///\n\n',...
                            numMopsToCalc,BF_thetime(toc(masterTimer)));
        clear masterTimer
        
        % Set sliced version of matching indicies across the range toCalc
        % Indices of MasterOperations corresponding to each Operation (i.e., each index of toCalc)
        par_OperationMasterInd = arrayfun(@(x)find([MasterOperations.ID]==x,1),[Operations(toCalc).MasterID]);
        par_MasterOperationsLabel = {MasterOperations.Label}; % Master labels
        par_OperationCodeString = {Operations(toCalc).CodeString}; % Code string for each operation to calculate (i.e., in toCalc)
        
        % --------------------------------------------------------------------------
		%% Assign all the results to the corresponding operations
        % --------------------------------------------------------------------------
		if doParallel
	        parfor jj = 1:numCalc
                [ffi(jj), qqi(jj), cti(jj)] = TS_compute_oploop(MasterOutput{par_OperationMasterInd(jj)}, ...
                                                   MasterCalcTime(par_OperationMasterInd(jj)), ...
                                                   par_MasterOperationsLabel{par_OperationMasterInd(jj)}, ...
                                                   par_OperationCodeString{jj},fid);
            end
		else
            for jj = 1:numCalc
                try
                    [ffi(jj), qqi(jj), cti(jj)] = TS_compute_oploop(MasterOutput{par_OperationMasterInd(jj)}, ...
                                                       MasterCalcTime(par_OperationMasterInd(jj)), ...
                                                       par_MasterOperationsLabel{par_OperationMasterInd(jj)}, ...
                                                       par_OperationCodeString{jj},fid);
                catch
                    fprintf(1,'---Error with %s\n',par_OperationCodeString{jj});
                    if (MasterOperations(par_OperationMasterInd(jj)).ID == 0)
                        error(['The operations database is corrupt: there is no link ' ...
                                'from ''%s'' to a master code'], par_OperationCodeString{jj});
                    else
                        fprintf(1,['Error retrieving element %s from %s.\n' ...
                                    'Activating keyboard active for debugging...\n'], ...
                                    par_OperationCodeString{jj}, par_MasterOperationsLabel{par_OperationMasterInd(jj)})
                        keyboard
                    end
                end
            end
        end
        
        % --------------------------------------------------------------------------
		%% Code special values:
        % --------------------------------------------------------------------------
		% (*) Errorless calculation: q = 0, Output = <real number>
		% (*) Fatal error: q = 1, Output = 0; (this is done already in the code above)

		% (*) Output = NaN: q = 2, Output = 0
		RR = isnan(ffi); % NaN
		if any(RR)
			qqi(RR) = 2; ffi(RR) = 0;
		end

		% (*) Output = Inf: q = 3, Output = 0
		RR = (isinf(ffi) & ffi > 0); % Inf
		if any(RR)
			qqi(RR) = 3; ffi(RR) = 0;
		end
		
        % (*) Output = -Inf: q = 4, Output = 0
		RR = (isinf(ffi) & ffi < 0);
		if any(RR)
			qqi(RR) = 4; ffi(RR) = 0;
		end
        
		% (*) Output is a complex number: q = 5, Output = 0
		RR = (imag(ffi)~=0);
		if any(RR)
			qqi(RR) = 5; ffi(RR) = 0;
		end

        % ------------------------------------------------------------------------------
		%% Store the calculated information back to local matrices
        % ------------------------------------------------------------------------------
        TS_DataMat(tsInd,toCalc) = ffi; % store outputs in TS_DataMat
		TS_CalcTime(tsInd,toCalc) = cti; % store calculation times in TS_CalcTime
		TS_Quality(tsInd,toCalc) = qqi; % store quality labels in TS_Quality
		% NB: the calculation time assigned for individual operations is the total calculation
		% time taken to evaluate the master code.

        % Calculate statistics for writing to file/screen
        % The number of calculated operations that returned real outputs without errors, numGood:
		numGood = sum(qqi == 0);
        % The number of fatal errors encountered, numErrors:
		numErrors = sum(qqi == 1);
        % The number of other special outputs, numSpecial:
		numSpecial = sum(qqi > 1);
    end
    
    % The time taken to calculate (or not, if numCalc = 0) all operations for this time series:
    times(i) = toc(bigTimer); clear bigTimer


    % --------------------------------------------------------------------------
    %% Calculation complete: display information about this time series calculation
    % --------------------------------------------------------------------------
	fprintf(fid,'********************************************************************\n')
    fprintf(fid,'; ; ; : : : : ; ; ; ;   %s    ; ; ; ; : : : ; ; ;\n',datestr(now))
    fprintf(fid,'oOoOo Calculation complete for %s (ts_id = %u, N = %u) oOoOo\n', ...
                            TimeSeries(tsInd).Name,TimeSeries(tsInd).ID,TimeSeries(tsInd).Length);
    if numCalc > 0 % Some amount of calculation was performed
	    fprintf(fid,'%u real-valued outputs, %u errors, %u special-valued outputs stored. [%u / %u]\n',...
	     					numGood,numErrors,numSpecial,numCalc,numOps);
		fprintf(fid,'All calculations for this time series took %s.\n',BF_thetime(times(i),1));
    else
    	fprintf(fid,'Nothing calculated! All %u operations already complete!!  0O0O0O0O0O0\n',numOps);
    end
    if i < numTimeSeries
        fprintf(fid,'- - - - - - - -  %u time series remaining - - - - - - - -\n',numTimeSeries-i);
    	fprintf(fid,'- - - - - - - -  %s remaining - - - - - - - - -\n', ...
                                        	BF_thetime(((numTimeSeries-i)*mean(times(1:i))),1));
    else % The final time series
        fprintf(fid,'- - - - - - - - - - All %u time series calculated! - - - - - - - - - -\n', ...
                                                    numTimeSeries);
    end
    fprintf(fid,'********************************************************************\n');

end


% --------------------------------------------------------------------------
% --------------------------------------------------------------------------
%% Finished calculating!!
% --------------------------------------------------------------------------
% --------------------------------------------------------------------------
fprintf(fid,['!! !! !! !! !! !! Calculation completed at %s !! !! ' ...
                                                '!! !! !!\n'],datestr(now))
fprintf(fid,'Calculations complete in a total of %s.\n',BF_thetime(sum(times),1))

% Save the local files for subsequent upload to the mySQL database
fprintf(1,'Saving all results to HCTSA_loc.mat...')
saveTimer = tic;
save('HCTSA_loc.mat','TS_DataMat','TS_CalcTime','TS_Quality','TimeSeries', ...
                                'Operations','MasterOperations','-v7.3')
fprintf(fid,' Saved in %s.\n',BF_thetime(toc(saveTimer)))
clear saveTimer

% Close the .log file:
if doLog
	fclose(fid);
end

fprintf(1,'Calculation complete!\n')
% ': you can now run SQL_store to upload the results to a mySQL database.\n'])

end
