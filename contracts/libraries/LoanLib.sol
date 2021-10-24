// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import { SafeMath }          from "../../modules/openzeppelin-contracts/contracts/math/SafeMath.sol";
import { IERC20, SafeERC20 } from "../../modules/openzeppelin-contracts/contracts/token/ERC20/SafeERC20.sol";
import { IMapleGlobals }     from "../../modules/util/contracts/interfaces/IMapleGlobals.sol";
import {
    IERC20Details as IERC20DetailsLike,  // NOTE: Necessary for https://github.com/ethereum/solidity/issues/9278
    IUniswapRouterLike,
    ICollateralLockerLike,
    IFundingLockerLike,
    IMapleGlobals as IMapleGlobalsLike,  // NOTE: Necessary for https://github.com/ethereum/solidity/issues/9278
    ILateFeeCalcLike,
    ILoanFactoryLike,
    IPremiumCalcLike,
    IRepaymentCalcLike,
    ILiquidityLockerLike,
    IPoolLike,
    IPoolFactoryLike
} from "../interfaces/Interfaces.sol";

import { Util } from "../../modules/util/contracts/Util.sol";

/// @title LoanLib is a library of utility functions used by Loan.
library LoanLib {

    using SafeMath  for uint256;
    using SafeERC20 for IERC20;

    enum State { Ready, Active, Matured, Expired, Liquidated }

    address public constant UNISWAP_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    /********************************/
    /*** Lender Utility Functions ***/
    /********************************/

    function drawdownChecks(
        address loanFactory,
        address borrower,
        bytes32 refinanceCommitment,
        address liquidityAsset,
        address fundingLocker,
        uint256 amount,
        uint256 requestAmount
    ) external view returns (uint256 fundingLockerBalance) {
        whenProtocolNotPaused(loanFactory);
        _isValidBorrower(borrower);

        // Prevent drawing down if new terms for a refinance are not yet accepted.
        require(refinanceCommitment == getEmptyRefinanceCommitment(), "L:IN_REFI");

        fundingLockerBalance = IERC20(liquidityAsset).balanceOf(fundingLocker);

        require(amount >= requestAmount && amount <= fundingLockerBalance, "L:AMT_OUT_RANGE");
    }

    function handleDrawdown(
        address loanFactory,
        address collateralAsset,
        address borrower,
        address collateralLocker,
        uint256 collateralRequired,
        uint256 amount,
        uint256 termDays,
        address fundingLocker
    ) external returns (address treasury, uint256 feePaid) {
        address globals = getGlobals(loanFactory);

        if (amount > uint256(0)) {
            // Transfer the required amount of collateral for drawdown from the Borrower to the CollateralLocker.
            IERC20(collateralAsset).safeTransferFrom(borrower, collateralLocker, collateralRequired);
        }

        uint256 treasuryAmt;
        ( treasury, feePaid, treasuryAmt) = _handleFees(globals, amount, termDays, fundingLocker);

        IFundingLockerLike(fundingLocker).pull(borrower, amount.sub(treasuryAmt).sub(feePaid));  // Transfer drawdown amount to the Borrower.

        // Drain remaining funds from the FundingLocker (amount equal to `excessReturned` plus `feePaid`)
        IFundingLockerLike(fundingLocker).drain();
    }

    function makePaymentsChecks(address superFactory, uint8 state) external view {
        whenProtocolNotPaused(superFactory);
        _isValidState(state, uint8(State.Active));
    }

    function fundLoanChecks(address superFactory) external view {
        whenProtocolNotPaused(superFactory);
        _isValidLender(superFactory);
    }

    /**
        @dev    Performs sanity checks on the data passed in Loan constructor.
        @param  globals         The instance of a MapleGlobals.
        @param  liquidityAsset  The contract address of the Liquidity Asset.
        @param  collateralAsset The contract address of the Collateral Asset.
        @param  specs           The contains specifications for this Loan.
     */
    function loanSanityChecks(address globals, address liquidityAsset, address collateralAsset, uint256[5] calldata specs) external view {
        require(IMapleGlobalsLike(globals).isValidLiquidityAsset(liquidityAsset),   "L:INV_LIQ_ASSET");
        require(IMapleGlobalsLike(globals).isValidCollateralAsset(collateralAsset), "L:INV_COL_ASSET");

        require(specs[2] != uint256(0),               "L:ZERO_PID");
        require(specs[1].mod(specs[2]) == uint256(0), "L:INV_TERM_DAYS");
        require(specs[3] > uint256(0),                "L:ZERO_REQ_AMT");
    }

    function unwindChecks(address superFactory, uint8 state) external view {
        whenProtocolNotPaused(superFactory);
        _isValidState(state, uint8(State.Ready));
    }

    /**
        @dev    Returns capital to Lenders, if the Borrower has not drawn down the Loan past the grace period.
        @param  liquidityAsset The IERC20 of the Liquidity Asset.
        @param  fundingLocker  The address of FundingLocker.
        @param  createdAt      The unix timestamp of Loan instantiation.
        @param  fundingPeriod  The duration of the funding period, after which funds can be reclaimed.
        @return excessReturned The amount of Liquidity Asset that was returned to the Loan from the FundingLocker.
     */
    function unwind(address liquidityAsset, address fundingLocker, uint256 createdAt, uint256 fundingPeriod) external returns (uint256 excessReturned) {
        // Only callable if Loan funding period has elapsed.
        require(block.timestamp > createdAt.add(fundingPeriod), "L:IN_FUND_PERIOD");

        // Account for existing balance in Loan.
        uint256 preBal = IERC20(liquidityAsset).balanceOf(address(this));

        // Drain funding from FundingLocker, transfers all the Liquidity Asset to this Loan.
        IFundingLockerLike(fundingLocker).drain();

        return IERC20(liquidityAsset).balanceOf(address(this)).sub(preBal);
    }

    function triggerDefaultChecks(
        address superFactory,
        uint8 state,
        uint256 nextPaymentDue,
        uint256 defaultGracePeriod,
        uint256 balance,
        uint256 totalSupply
    ) external view {
        whenProtocolNotPaused(superFactory);
        _isValidState(state, uint8(State.Active));
        _canTriggerDefault(nextPaymentDue, defaultGracePeriod, superFactory, balance, totalSupply);
    }

    /**
        @dev    Liquidates a Borrower's collateral, via Uniswap, when a default is triggered.
        @dev    Only the Loan can call this function.
        @param  collateralAsset  The IERC20 of the Collateral Asset.
        @param  liquidityAsset   The address of Liquidity Asset.
        @param  superFactory     The factory that instantiated Loan.
        @param  collateralLocker The address of CollateralLocker.
        @return amountLiquidated The amount of Collateral Asset that was liquidated.
        @return amountRecovered  The amount of Liquidity Asset that was returned to the Loan from the liquidation.
     */
    function liquidateCollateral(
        address  collateralAsset,
        address liquidityAsset,
        address superFactory,
        address collateralLocker
    )
        external
        returns (
            uint256 amountLiquidated,
            uint256 amountRecovered
        )
    {
        // Get the liquidation amount from CollateralLocker.
        uint256 liquidationAmt = IERC20(collateralAsset).balanceOf(address(collateralLocker));

        // Pull the Collateral Asset from CollateralLocker.
        ICollateralLockerLike(collateralLocker).pull(address(this), liquidationAmt);

        if (collateralAsset == liquidityAsset || liquidationAmt == uint256(0)) return (liquidationAmt, liquidationAmt);

        IERC20(collateralAsset).safeApprove(UNISWAP_ROUTER, uint256(0));
        IERC20(collateralAsset).safeApprove(UNISWAP_ROUTER, liquidationAmt);

        address globals = getGlobals(superFactory);

        // Get minimum amount of loan asset get after swapping collateral asset.
        uint256 minAmount = Util.calcMinAmount(IMapleGlobals(globals), address(collateralAsset), liquidityAsset, liquidationAmt);

        // Generate Uniswap path.
        address uniswapAssetForPath = IMapleGlobalsLike(globals).defaultUniswapPath(address(collateralAsset), liquidityAsset);
        bool middleAsset = uniswapAssetForPath != liquidityAsset && uniswapAssetForPath != address(0);

        address[] memory path = new address[](middleAsset ? 3 : 2);

        path[0] = collateralAsset;
        path[1] = middleAsset ? uniswapAssetForPath : liquidityAsset;

        if (middleAsset) path[2] = liquidityAsset;

        // Swap collateralAsset for Liquidity Asset.
        uint256[] memory returnAmounts = IUniswapRouterLike(UNISWAP_ROUTER).swapExactTokensForTokens(
            liquidationAmt,
            minAmount.sub(minAmount.mul(IMapleGlobalsLike(globals).maxSwapSlippage()).div(10_000)),
            path,
            address(this),
            block.timestamp
        );

        return(returnAmounts[0], returnAmounts[path.length - 1]);
    }

    function refinance(bytes32 refinanceCommitment, bytes[] calldata calls) external {
        require(refinanceCommitment == generateRefinanceCommitment(calls), "L:REFI_MISMATCH");

        for (uint256 i; i < calls.length; ++i) {
            ( bool success, ) = address(this).call(calls[i]);
            require(success, "L:REFI_STEP_FAILED");
        }
    }

    /**********************************/
    /*** Governor Utility Functions ***/
    /**********************************/

    /**
        @dev   Transfers any locked funds to the Governor.
        @dev   Only the Governor can call this function.
        @param token          The address of the token to be reclaimed.
        @param liquidityAsset The address of token that is used by the loan for drawdown and payments.
        @param loanFactory    The instance of a LoanFactory.
     */
    function reclaimERC20(address token, address liquidityAsset, address loanFactory) external {
        require(msg.sender == IMapleGlobalsLike(getGlobals(loanFactory)).governor(), "L:NOT_GOV");
        require(token != liquidityAsset && token != address(0), "L:INV_TOKEN");
        IERC20(token).safeTransfer(msg.sender, IERC20(token).balanceOf(address(this)));
    }

    /************************/
    /*** Getter Functions ***/
    /************************/

    /**
        @dev    Returns information on next payment amount.
        @param  repaymentCalc   The address of RepaymentCalc.
        @param  nextPaymentDue  The unix timestamp of when payment is due.
        @param  lateFeeCalc     The address of LateFeeCalc.
        @return total           The entitled total amount needed to be paid in the next payment (Principal + Interest only when the next payment is last payment of the Loan).
        @return principal       The entitled principal amount needed to be paid in the next payment.
        @return interest        The entitled interest amount needed to be paid in the next payment.
        @return _nextPaymentDue The payment due date.
        @return paymentLate     Whether payment is late.
     */
    function getNextPayment(
        address repaymentCalc,
        uint256 nextPaymentDue,
        address lateFeeCalc
    )
        external
        view
        returns (
            uint256 total,
            uint256 principal,
            uint256 interest,
            uint256 _nextPaymentDue,
            bool    paymentLate
        )
    {
        _nextPaymentDue  = nextPaymentDue;

        // Get next payment amounts from RepaymentCalc.
        (total, principal, interest) = IRepaymentCalcLike(repaymentCalc).getNextPayment(address(this));

        paymentLate = block.timestamp > _nextPaymentDue;

        // If payment is late, add late fees.
        if (paymentLate) {
            uint256 lateFee = ILateFeeCalcLike(lateFeeCalc).getLateFee(interest);

            total    = total.add(lateFee);
            interest = interest.add(lateFee);
        }
    }

    /**
        @dev    Returns information on full payment amount.
        @param  repaymentCalc   The address of RepaymentCalc.
        @param  nextPaymentDue  The unix timestamp of when payment is due.
        @param  lateFeeCalc     The address of LateFeeCalc.
        @param  premiumCalc     The address of PremiumCalc.
        @return total           The Principal + Interest for the full payment.
        @return principal       The entitled principal amount needed to be paid in the full payment.
        @return interest        The entitled interest amount needed to be paid in the full payment.
     */
    function getFullPayment(
        address repaymentCalc,
        uint256 nextPaymentDue,
        address lateFeeCalc,
        address premiumCalc
    )
        external
        view
        returns (
            uint256 total,
            uint256 principal,
            uint256 interest
        )
    {
        (total, principal, interest) = IPremiumCalcLike(premiumCalc).getPremiumPayment(address(this));

        if (block.timestamp <= nextPaymentDue) return (total, principal, interest);

        // If payment is late, calculate and add late fees using interest amount from regular payment.
        (,, uint256 regInterest) = IRepaymentCalcLike(repaymentCalc).getNextPayment(address(this));

        uint256 lateFee = ILateFeeCalcLike(lateFeeCalc).getLateFee(regInterest);

        total    = total.add(lateFee);
        interest = interest.add(lateFee);
    }

    /**
        @dev    Calculates collateral required to drawdown amount.
        @param  collateralAsset The IERC20 of the Collateral Asset.
        @param  liquidityAsset  The IERC20 of the Liquidity Asset.
        @param  collateralRatio The percentage of drawdown value that must be posted as collateral.
        @param  globals         A MapleGlobals contract address.
        @param  amt             The drawdown amount.
        @return The amount of Collateral Asset required to post in CollateralLocker for given drawdown amount.
     */
    function collateralRequiredForDrawdown(
        address collateralAsset,
        address liquidityAsset,
        uint256 collateralRatio,
        address globals,
        uint256 amt
    )
        external
        view
        returns (uint256)
    {
        uint256 wad = toWad(amt, liquidityAsset);  // Convert to WAD precision.

        // Fetch current value of Liquidity Asset and Collateral Asset (Chainlink oracles provide 8 decimal precision).
        uint256 liquidityAssetPrice  = IMapleGlobalsLike(globals).getLatestPrice(liquidityAsset);
        uint256 collateralPrice = IMapleGlobalsLike(globals).getLatestPrice(collateralAsset);

        // Calculate collateral required.
        uint256 collateralRequiredUSD = wad.mul(liquidityAssetPrice).mul(collateralRatio).div(10_000);  // 18 + 8 = 26 decimals
        uint256 collateralRequiredWAD = collateralRequiredUSD.div(collateralPrice);                     // 26 - 8 = 18 decimals

        return collateralRequiredWAD.mul(10 ** IERC20DetailsLike(collateralAsset).decimals()).div(10 ** 18);  // 18 + collateralAssetDecimals - 18 = collateralAssetDecimals
    }

    /*******************************/
    /*** Public Helper Functions ***/
    /*******************************/

    /**
        @dev Returns the MapleGlobals address given a LoanFactory address.
     */
    function getGlobals(address loanFactory) public view returns (address) {
        return ILoanFactoryLike(loanFactory).globals();
    }

    /**
        @dev Converts to WAD precision.
     */
    function toWad(uint256 amt, address liquidityAsset) public view returns (uint256) {
        return amt.mul(10 ** 18).div(10 ** IERC20DetailsLike(liquidityAsset).decimals());
    }

    function getEmptyRefinanceCommitment() public pure returns (bytes32) {
        return keccak256(abi.encode(new bytes[](0)));
    }

    function generateRefinanceCommitment(bytes[] calldata calls) public pure returns (bytes32) {
        return keccak256(abi.encode(calls));
    }

    /**
        @dev Checks that the protocol is not in a paused state.
     */
    function whenProtocolNotPaused(address loanFactory) public view {
        require(!IMapleGlobalsLike(getGlobals(loanFactory)).protocolPaused(), "L:PROTO_PAUSED");
    }

    /*********************************/
    /*** Internal Helper Functions ***/
    /*********************************/

    /**
        @dev    Returns if a default can be triggered.
        @param  nextPaymentDue     The unix timestamp of when payment is due.
        @param  defaultGracePeriod The amount of time after the next payment is due that a Borrower has before a liquidation can occur.
        @param  superFactory       The factory that instantiated Loan.
        @param  balance            The LoanFDT balance of account trying to trigger a default.
        @param  totalSupply        The total supply of LoanFDT.
     */
    function _canTriggerDefault(
        uint256 nextPaymentDue,
        uint256 defaultGracePeriod,
        address superFactory,
        uint256 balance,
        uint256 totalSupply
    ) internal view {
        bool pastDefaultGracePeriod = block.timestamp > nextPaymentDue.add(defaultGracePeriod);

        // Check if the Loan is past the default grace period and that the account triggering the default has a percentage of total LoanFDTs
        // that is greater than the minimum equity needed (specified in globals)
        require(
            pastDefaultGracePeriod && balance >= ((totalSupply * IMapleGlobalsLike(getGlobals(superFactory)).minLoanEquity()) / 10_000),
            "L:LIQ_FAILED"
        );
    }

    function _handleFees(address globals, uint256 amt, uint256 termDays, address fundingLocker)
        internal
        returns (
            address treasury,
            uint256 feePaid,
            uint256 treasuryAmt
        )
    {
        // Transfer funding amount from the FundingLocker to the Borrower, then drain remaining funds to the Loan.
        treasury    = IMapleGlobalsLike(globals).mapleTreasury();
        feePaid     = _getFee(amt, IMapleGlobalsLike(globals).investorFee(), termDays); // Update fees paid for `claim()`.
        treasuryAmt = _getFee(amt, IMapleGlobalsLike(globals).treasuryFee(), termDays); // Calculate amount to send to the MapleTreasury.

        IFundingLockerLike(fundingLocker).pull(treasury, treasuryAmt);                        // Send the treasury fee directly to the MapleTreasury.
    }

    function _getFee(uint256 amount, uint256 feeRate, uint256 termDays) internal pure returns (uint256) {
        return amount.mul(feeRate).mul(termDays).div(uint256(3_650_000));
    }

    /**
        @dev Checks that `msg.sender` is the Borrower.
     */
    function _isValidBorrower(address borrower) internal view {
        require(msg.sender == borrower, "L:INV_BORROWER");
    }

    /**
        @dev Checks that `msg.sender` is a Lender (LiquidityLocker) that is using an approved Pool to fund the Loan.
     */
    function _isValidLender(address superFactory) internal view {
        address pool        = ILiquidityLockerLike(msg.sender).pool();
        address poolFactory = IPoolLike(pool).superFactory();
        require(
            IMapleGlobalsLike(getGlobals(superFactory)).isValidPoolFactory(poolFactory) &&
            IPoolFactoryLike(poolFactory).isPool(pool),
            "L:INV_LENDER"
        );
    }

    /**
        @dev   Checks that the current state of the Loan matches the expected state.
        @param state         Loan state.
        @param expectedState Expected Loan state.
     */
    function _isValidState(uint8 state, uint8 expectedState) internal pure {
        require(state == expectedState, "L:INV_STATE");
    }

}
