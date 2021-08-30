// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.6.11;

import { TestUtils } from "../../modules/contract-test-utils/contracts/test.sol";

import { LoanFactory } from "../LoanFactory.sol";
import { Loan }        from "../Loan.sol";

import { Borrower } from "./accounts/Borrower.sol";

import {
    CollateralLockerFactoryMock,
    FundingLockerFactoryMock,
    GlobalsMock,
    MintableToken
} from "./mocks/Mocks.sol";

contract LoanConstructorTest is TestUtils {

    uint8 internal constant CL_FACTORY = 0;
    uint8 internal constant FL_FACTORY = 2;

    uint8 internal constant INTEREST_CALC_TYPE = 10;
    uint8 internal constant LATEFEE_CALC_TYPE  = 11;
    uint8 internal constant PREMIUM_CALC_TYPE  = 12;

    GlobalsMock internal globals;
    LoanFactory internal loanFactory;

    address internal collateralLockerFactory;
    address internal fundingLockerFactory;

    address internal constant repaymentCalc = address(111);
    address internal constant lateFeeCalc   = address(222);
    address internal constant premiumCalc   = address(333);

    function setUp() external {
        globals     = new GlobalsMock(address(this));
        loanFactory = new LoanFactory(address(globals));

        collateralLockerFactory = address(new CollateralLockerFactoryMock());
        fundingLockerFactory    = address(new FundingLockerFactoryMock());

        globals.setCalcValidity(repaymentCalc, INTEREST_CALC_TYPE, true);
        globals.setCalcValidity(lateFeeCalc,   LATEFEE_CALC_TYPE,  true);
        globals.setCalcValidity(premiumCalc,   PREMIUM_CALC_TYPE,  true);
    }

    function constrictFuzzedIntervalAndTerm(uint256 paymentIntervalDays, uint256 termDays) internal pure returns (uint256, uint256) {
        paymentIntervalDays = constrictToRange(paymentIntervalDays, 1, type(uint256).max / 1 days);
        termDays            = paymentIntervalDays * (termDays / paymentIntervalDays);

        return (paymentIntervalDays, termDays);
    }

    function test_constructor(
        uint256 apr,
        uint256 termDays,
        uint256 paymentIntervalDays,
        uint256 requestAmount,
        uint256 collateralRatio
    ) external {
        globals.setLiquidityAssetValidity(address(1),  true);
        globals.setCollateralAssetValidity(address(2), true);

        globals.setSubFactoryValidity(address(loanFactory), address(fundingLockerFactory),    FL_FACTORY, true);
        globals.setSubFactoryValidity(address(loanFactory), address(collateralLockerFactory), CL_FACTORY, true);

        (paymentIntervalDays, termDays) = constrictFuzzedIntervalAndTerm(paymentIntervalDays, termDays);
        requestAmount                   = constrictToRange(requestAmount, 1, type(uint256).max);

        uint256[5] memory specs = [apr, termDays, paymentIntervalDays, requestAmount, collateralRatio];

        Loan loan = Loan(loanFactory.createLoan(
            address(1),
            address(2),
            fundingLockerFactory,
            collateralLockerFactory,
            specs,
            [repaymentCalc, lateFeeCalc, premiumCalc]
        ));

        assertEq(loan.borrower(),               address(this));
        assertEq(loan.liquidityAsset(),         address(1));
        assertEq(loan.collateralAsset(),        address(2));
        assertEq(loan.flFactory(),              address(fundingLockerFactory));
        assertEq(loan.clFactory(),              address(collateralLockerFactory));
        assertEq(loan.createdAt(),              block.timestamp);
        assertEq(loan.apr(),                    apr);
        assertEq(loan.termDays(),               termDays);
        assertEq(loan.paymentsRemaining(),      termDays / paymentIntervalDays);
        assertEq(loan.paymentIntervalSeconds(), paymentIntervalDays * 1 days);
        assertEq(loan.requestAmount(),          requestAmount);
        assertEq(loan.collateralRatio(),        collateralRatio);
        assertEq(loan.fundingPeriod(),          globals.fundingPeriod());
        assertEq(loan.defaultGracePeriod(),     globals.defaultGracePeriod());
        assertEq(loan.repaymentCalc(),          repaymentCalc);
        assertEq(loan.lateFeeCalc(),            lateFeeCalc);
        assertEq(loan.premiumCalc(),            premiumCalc);
        assertEq(loan.superFactory(),           address(loanFactory));
        assertEq(uint256(loan.loanState()),     0);

        assertTrue(loan.collateralLocker() != address(0));
        assertTrue(loan.fundingLocker()    != address(0));
    }

    function testFail_constructor_withInvalidLiquidityAsset(
        uint256 apr,
        uint256 termDays,
        uint256 paymentIntervalDays,
        uint256 requestAmount,
        uint256 collateralRatio
    ) external {
        globals.setSubFactoryValidity(address(loanFactory), address(fundingLockerFactory),    FL_FACTORY, true);
        globals.setSubFactoryValidity(address(loanFactory), address(collateralLockerFactory), CL_FACTORY, true);

        (paymentIntervalDays, termDays) = constrictFuzzedIntervalAndTerm(paymentIntervalDays, termDays);
        requestAmount                   = constrictToRange(requestAmount, 1, type(uint256).max);

        uint256[5] memory specs = [apr, termDays, paymentIntervalDays, requestAmount, collateralRatio];

        loanFactory.createLoan(
            address(888),
            address(999),
            fundingLockerFactory,
            collateralLockerFactory,
            specs,
            [repaymentCalc, lateFeeCalc, premiumCalc]
        );
    }

    function testFail_constructor_withInvalidCollateralAsset(
        uint256 apr,
        uint256 termDays,
        uint256 paymentIntervalDays,
        uint256 requestAmount,
        uint256 collateralRatio
    ) external {
        globals.setLiquidityAssetValidity(address(888), true);

        globals.setSubFactoryValidity(address(loanFactory), address(fundingLockerFactory),    FL_FACTORY, true);
        globals.setSubFactoryValidity(address(loanFactory), address(collateralLockerFactory), CL_FACTORY, true);

        (paymentIntervalDays, termDays) = constrictFuzzedIntervalAndTerm(paymentIntervalDays, termDays);
        requestAmount                   = constrictToRange(requestAmount, 1, type(uint256).max);

        uint256[5] memory specs = [apr, termDays, paymentIntervalDays, requestAmount, collateralRatio];

        loanFactory.createLoan(
            address(888),
            address(999),
            fundingLockerFactory,
            collateralLockerFactory,
            specs,
            [repaymentCalc, lateFeeCalc, premiumCalc]
        );
    }

    // TODO: test failure creating a loan with various invalid specs

}

contract LoanTestDrawDown is TestUtils {

    uint8 internal constant CL_FACTORY = 0;
    uint8 internal constant FL_FACTORY = 2;

    uint8 internal constant INTEREST_CALC_TYPE = 10;
    uint8 internal constant LATEFEE_CALC_TYPE  = 11;
    uint8 internal constant PREMIUM_CALC_TYPE  = 12;

    Borrower      internal borrower;
    GlobalsMock   internal globals;
    LoanFactory   internal loanFactory;
    MintableToken internal token;

    address internal collateralLockerFactory;
    address internal fundingLockerFactory;

    address internal constant repaymentCalc = address(111);
    address internal constant lateFeeCalc   = address(222);
    address internal constant premiumCalc   = address(333);

    function setUp() external {
        borrower    = new Borrower();
        globals     = new GlobalsMock(address(this));
        loanFactory = new LoanFactory(address(globals));
        token       = new MintableToken("Test", "TST");

        collateralLockerFactory = address(new CollateralLockerFactoryMock());
        fundingLockerFactory    = address(new FundingLockerFactoryMock());

        globals.setCalcValidity(repaymentCalc, INTEREST_CALC_TYPE, true);
        globals.setCalcValidity(lateFeeCalc,   LATEFEE_CALC_TYPE,  true);
        globals.setCalcValidity(premiumCalc,   PREMIUM_CALC_TYPE,  true);
    }

    function test_annualizedDrawdownFees() external {
        uint256 apr                 = 0;
        uint256 collateralRatio     = 10_000;
        uint256 paymentIntervalDays = 1;
        uint256 requestAmount       = 10_000_000;
        uint256 termDays            = 10;

        globals.setLiquidityAssetValidity(address(token), true);
        globals.setCollateralAssetValidity(address(token), true);

        globals.setSubFactoryValidity(address(loanFactory), address(fundingLockerFactory),    FL_FACTORY, true);
        globals.setSubFactoryValidity(address(loanFactory), address(collateralLockerFactory), CL_FACTORY, true);

        uint256[5] memory specs = [apr, termDays, paymentIntervalDays, requestAmount, collateralRatio];

        address loan = borrower.loanFactory_createLoan(
            address(loanFactory),
            address(token),
            address(token),
            fundingLockerFactory,
            collateralLockerFactory,
            specs,
            [repaymentCalc, lateFeeCalc, premiumCalc]
        );

        // Funding Locker needs to have enough to draw down on
        token.mint(Loan(loan).fundingLocker(), requestAmount);

        // Borrower needs collateral approve for the loan
        token.mint(address(borrower), requestAmount);
        borrower.erc20_approve(address(token), loan, requestAmount);

        // Mock the price of the token, the set investor fee (2%), and the treasury fee (1%)
        globals.setLatestPrice(address(token), 100);
        globals.setInvestorFee(200);
        globals.setTreasuryFee(100);

        borrower.loan_drawdown(loan, requestAmount);

        assertEq(Loan(loan).feePaid(),                     5479);
        assertEq(token.balanceOf(globals.mapleTreasury()), 2739);
    }

}
