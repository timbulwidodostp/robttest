*! 1.0.0 20200707
capture program drop robttest
program robttest, eclass sortpreserve
	syntax [if] [in], ///
		[ ///
			K(int -1) ///
			verbose ///
		]

	// Locate "all.sd" file
	qui findfile "all.sd"
	local all_sd `r(fn)'
	
	// Create rtt tempvar
	tempvar rtt_sel
		
//	capture noisily setscores
//	if _rc!=0 exit
	rtt_setBM
	rtt_setscores, rtt_sel(`rtt_sel')
	matrix b=e(b)
	local na : colnames e(V)
	matrix robCis =e(b)'*(1,1)
	matrix robCI =(1,2)
	matrix robpval=(1)
	
	matrix robpvals=e(b)
	tokenize `na'
	qui sum `rtt_sel', detail
	
	// Set k if not given explicitely
	if `k' == -1 {
		if r(sum) >= 50 local k 8
		else if r(sum)>=25 local k 4
		else {
			di as error "number of independent observations/clusters smaller than 25"
			exit 499
		}
		di as text "Using k = `k' based on number of observations/clusters (`r(sum)')"
	}
	
	matrix WR = J(colsof(b),`k', .) 
	matrix rownames WR = `na'
	matrix WL = WR
	//matrix myv = e(b)
	
	// Loop through covariates
	local i = 1
	while "``i''" != "" {
		tempvar w
		matrix coef = r(sum)*rtt_Bread[`i', 1...]
		qui matrix score `w' = coef if `rtt_sel' == 1
		qui replace `w' = `w' + b[1,`i'] if `rtt_sel' == 1
		mata setCIfromS(`k', "`w'", "`rtt_sel'", "`all_sd'")
		matrix robCis[`i', 1] = robCI[1, 1..2]
		mata setpvalfromS(`k', "`w'", "`rtt_sel'", "`all_sd'")
		matrix robpvals[1,`i'] = robpval[1, 1]
		matrix Wextremes = Wextremes'
		matrix WR[`i', 1] = Wextremes[1, 1...]
		matrix WL[`i', 1] = Wextremes[2, 1...]
		local ++i
	}
	matrix A=(b \ robpvals \ robCis')'
	matrix colnames A = "Coef" p-val "95% Conf" "Interval "
	local n = rowsof(A)
	local ands = `n'*"&"
	local rs &-`ands'
	matlist A, border(all) title("Results using robust t-test, k = `k':") cspec(o2& %12s | %9.0g o2 & o1 %5.3f & o2 %9.0g o1 &  o1 %9.0g o2&) rspec(`rs')
	if "`verbose'" != "" {
		matlist WR, border(rows) title("Normalized largest k = `k' terms, right tail:") names(rows)
		matlist WL, border(rows) title("Normalized largest k = `k' terms, left tail:") names(rows)
	}
	
	// Return results
	ereturn matrix rob_CIs = robCis
	ereturn matrix rob_pvals = robpvals
	ereturn matrix rob_WR = WR
	ereturn matrix rob_WL = WL
	
	// Drop rtt_score variables
	// TODO: Fix this with tempvars (variable number is the issue)
	cap drop rtt_score*
end

//------------------------------------------------------------------------------
// Define auxiliary programs
//------------------------------------------------------------------------------

capture program drop rtt_setBM
program rtt_setBM
	matrix rtt_Bread=e(V_modelbased)
	if( rtt_Bread[1,1]==.) {
		disp "e(V_modelbased) missing; aborting"
		exit(999)
	}
end program

capture program drop rtt_setscores
program rtt_setscores, sortpreserve
	syntax, rtt_sel(name)
	tempvar e
	local slist ""
	quietly{
	if(e(cmd)=="regress" | e(cmd)=="logit" | e(cmd)=="probit"){
		predict `e' if e(sample),sc
		local na : colnames e(V)
		tokenize `na'
		local i = 1
		while "``i''" != "" {
			capture drop rtt_score`i'
			if("``i''"=="_cons") gen rtt_score`i'=`e' if e(sample)
			else gen rtt_score`i'=`e'*``i'' if e(sample)
			local slist "`slist' rtt_score`i'"
			local ++i
		}
	}
	else if(e(cmd)=="areg"){
		predict `e' if e(sample),sc
		sort `e(absvar)'
		local na : colnames e(V)
		tokenize `na'
		local i = 1
		while "``i''" != "" {
			capture drop rtt_score`i'
			if("``i''"=="_cons") gen rtt_score`i'=`e' if e(sample)
			else{
				tempvar x
				by `e(absvar)': egen `x'=mean(``i'') if e(sample)
				sum  ``i'' if e(sample)			
				gen rtt_score`i'=`e'*(``i''-`x'+`r(mean)') if e(sample)
			}
			local slist "`slist' rtt_score`i'"
			local ++i
		}
	}
	else if(e(cmd)=="ivregress"){
		tempvar stata_scr
		predict `stata_scr'*,sc
		
		local j=`: word count `e(instd)''+1
		gen `e'=`stata_scr'`j'
		di `j'
		local na : colnames e(V)
		tokenize `na'
		local i = 1
		while "``i''" != "" {
			capture drop rtt_score`i'
			if (`i'<`j') gen rtt_score`i'=`stata_scr'`i' if e(sample)
			else{
				if("``i''"=="_cons") gen rtt_score`i'=`e' if e(sample)
				else gen rtt_score`i'=`e'*``i'' if e(sample)
			}
			local slist "`slist' rtt_score`i'"
			local ++i
		}
	}
	else {
		di "rtt_setscores does not support " e(cmd)
		exit(999)
	}
	
	matrix colnames rtt_Bread = `slist'
	gen `rtt_sel'=0
	if( "`e(clustvar)'"=="") qui replace `rtt_sel'=1 if e(sample)
	else{
		tempvar TotScore
		tempvar es
		gen `es'=0 if e(sample)
		sort `e(clustvar)' `es'
		local i = 1
		while "``i''" != ""{
			capture drop `TotScore'
			by `e(clustvar)': egen `TotScore'=total(rtt_score`i') if e(sample)
			replace rtt_score`i'=`TotScore'
			by `e(clustvar)': replace `rtt_sel' = 1 if _n==1 & e(sample)
			local ++i
		}
	}
	}
end

capture program drop analyticV
program analyticV
// compares stata covariance matrix with covariance matrix implied by scores and sandwich formula
// should return values close to one or something is wrong
    matrix rtt_Bread=e(V_modelbased)
    if( rtt_Bread[1,1]==.) {
        disp as text "e(V_modelbased) missing; aborting"
        exit(999)
    }   
    tempvar rtt_sel
    rtt_setscores, rtt_sel(`rtt_sel')
    qui corr rtt_score* if `rtt_sel' == 1, cov
    tempname V
    mat `V'= r(N)*rtt_Bread*r(C)*rtt_Bread'
	di "number of terms in score:", r(N)
	mata Vx=st_matrix("`V'")
	mata V=st_matrix("e(V)")
	di "ratio of STATA covariance matrix and standard Sandwich formula for first 10 elements"
	mata Vx=Vx:/V
	mata Vx[1::min((10,cols(Vx))),1::min((10,cols(Vx)))]
end


findfile "heavymeanmata.do"
include "`r(fn)'"

exit


//rtt_setBM
//rtt_setscores
//rtt_analyticV
