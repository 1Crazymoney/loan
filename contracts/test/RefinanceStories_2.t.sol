// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.7;

import { DSTest }    from "../../modules/ds-test/src/test.sol";
import { IERC20 }    from "../../modules/erc20/src/interfaces/IERC20.sol";
import { MockERC20 } from "../../modules/erc20/src/test/mocks/MockERC20.sol";

import { Borrower } from "./accounts/Borrower.sol";
import { Lender }   from "./accounts/Lender.sol";

import { MapleLoan_2 } from "./../MapleLoan_2.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

contract ConstructableMapleLoan is MapleLoan_2 {

    constructor(address borrower_, address[2] memory assets_, uint256[6] memory parameters_, uint256[2] memory amounts_) {
        _initialize(borrower_, assets_, parameters_, amounts_);
    }

}


// Inheriting just a lazy way to get the correct storage
contract Simple_Refinancer is MapleLoan_2 {
    
    uint256 internal constant new_interestRate = 10_000;     // The annualized interest rate of the loan.
    uint256 internal constant new_collateralRequired = 500_000;  // The collateral the borrower is expected to put up to draw down all _principalRequested.
    uint256 internal constant new_principalRequested = 2_000_000;  // The funds the borrowers wants to borrower.
    uint256 internal constant new_drawableFunds = 1_000_0000;       // The amount of funds that can be drawn down.
    uint256 internal constant new_claimableFunds = 0;      // The amount of funds that the lender can claim (principal repayments, interest fees, and late fees).
    uint256 internal constant new_collateral = 300_000;          // The amount of collateral, in collateral asset, that is currently posted.
    uint256 internal constant new_paymentsRemaining = 29;   // The number of payment remaining.
    uint256 internal constant new_principal = 1_000_000; 

    fallback() external {
        _interestRate = new_interestRate;     // The annualized interest rate of the loan.
        _collateralRequired = new_collateralRequired;  // The collateral the borrower is expected to put up to draw down all _principalRequested.
        _principalRequested = new_principalRequested;  // The funds the borrowers wants to borrower.
        _drawableFunds = new_drawableFunds;       // The amount of funds that can be drawn down.
        _claimableFunds = new_claimableFunds;      // The amount of funds that the lender can claim (principal repayments, interest fees, and late fees).
        _collateral = new_collateral;          // The amount of collateral, in collateral asset, that is currently posted.
        _paymentsRemaining = new_paymentsRemaining;   // The number of payment remaining.
        _principal = new_principal;

        require(_collateralMaintained(), "ML:ANT:COLLATERAL_NOT_MAINTAINED");

    }
}

// Inheriting just a lazy way to get the correct storage
contract Complex_Refinancer is MapleLoan_2 {
    
    address internal constant new_collateralAsset = address(888);
    uint256 internal constant new_interestRate = 10_000;     // The annualized interest rate of the loan.
    uint256 internal constant new_collateralRequired = 500_000;  // The collateral the borrower is expected to put up to draw down all _principalRequested.
    uint256 internal constant new_principalRequested = 2_000_000;  // The funds the borrowers wants to borrower.
    uint256 internal constant new_drawableFunds = 1_000_0000;       // The amount of funds that can be drawn down.
    uint256 internal constant new_claimableFunds = 0;      // The amount of funds that the lender can claim (principal repayments, interest fees, and late fees).
    uint256 internal constant new_collateral = 300_000;          // The amount of collateral, in collateral asset, that is currently posted.
    uint256 internal constant new_paymentsRemaining = 29;   // The number of payment remaining.
    uint256 internal constant new_principal = 1_000_000; 

    fallback() external {

        // Here we can execute any logic that we might want to perform during a refinance. Might be moving money, wait for certain times, etc.

        // Here are some examples:
        require(_paymentsRemaining == 1);    //This will make refinance callable only in the last payment cycle
        require(block.timestamp > 9999999); // Specif time that refinance will get into effect
        
        // swap the collateral to another asset
        IERC20(_collateralAsset).transfer(_borrower, IERC20(_collateralAsset).balanceOf(address(this)));
        IERC20(new_collateralAsset).transferFrom(_borrower, address(this), new_collateral);
        _collateralAsset = new_collateralAsset;

        //.. 

    }
}

contract RefinanceTest is DSTest {

    Hevm hevm;

    MockERC20              token;   
    Borrower               borrower;
    Lender                 lender;
    ConstructableMapleLoan loan;

    constructor() {
        hevm = Hevm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));
    }

    // This function initializes and makes a payment
    function setUpOngoinLoan() internal {

        token    = new MockERC20("Test", "TST", 0);
        borrower = new Borrower();
        lender   = new Lender();

        token.mint(address(borrower), 1_000_000);
        token.mint(address(lender),   1_000_000);

        address[2] memory assets = [address(token), address(token)];

        uint256[6] memory parameters = [
            uint256(0),
            uint256(10 days),
            uint256(120_000),
            uint256(100_000),
            uint256(365 days / 6),
            uint256(6)
        ];

        uint256[2] memory requests = [uint256(300_000), uint256(1_000_000)];

        loan = new ConstructableMapleLoan(address(borrower), assets, parameters, requests);

        lender.erc20_transfer(address(token), address(loan), 1_000_000);

        assertTrue(lender.try_loan_lend(address(loan), address(lender)), "Cannot lend");

        assertEq(loan.drawableFunds(), 1_000_000, "Different drawable funds");

        borrower.erc20_transfer(address(token), address(loan), 300_000);

        assertTrue(borrower.try_loan_postCollateral(address(loan)),                              "Cannot post");
        assertTrue(borrower.try_loan_drawdownFunds(address(loan), 1_000_000, address(borrower)), "Cannot drawdown");

        assertEq(loan.drawableFunds(), 0, "Different drawable funds");

        // Check details for upcoming payment #1
        ( uint256 principalPortion, uint256 interestPortion, uint256 lateFeesPortion ) = loan.getNextPaymentsBreakDown(1);

        assertEq(principalPortion,         158_526,   "Different principal");
        assertEq(interestPortion,          20_000,    "Different interest");
        assertEq(lateFeesPortion,          0,         "Different late fees");
        assertEq(loan.paymentsRemaining(), 6,         "Different payments remaining");
        assertEq(loan.principal(),         1_000_000, "Different payments remaining");

        // Warp to 1 second before payment #1 becomes late
        hevm.warp(loan.nextPaymentDueDate() - 1);

        // Make payment #1
        borrower.erc20_transfer(address(token), address(loan), 178_526);

        assertTrue(borrower.try_loan_makePayment(address(loan)), "Cannot pay");
    }

    function test_refinance_story_increasePrincipalAndCollateral() external {
        setUpOngoinLoan();

        Simple_Refinancer refinancer = new Simple_Refinancer();


        uint256 extraPrincipal  = loan.principal() + 1_000_000 * 10**18;
        uint256 extraCollateral = loan.collateral() + 300_000 * 1**18;

        // Fake parameters here
        address[2] memory newAssets = [address(refinancer), address(0)];
 
        uint256[13] memory newTerms = [
            uint256(0),  
            uint256(0),      
            uint256(0),     
            uint256(0),      
            uint256(0),  
            uint256(0),   
            uint256(0),  
            uint256(0),       
            uint256(0),      
            uint256(0),           
            uint256(0),  
            uint256(0),   
            uint256(0)           
        ];
        uint256 totalPayments =  loan.paymentsRemaining() + 24;
        borrower.loan_proposeNewTerms(address(loan), newAssets, newTerms);

        lender.loan_acceptNewTerms(address(loan), newAssets, newTerms);

        assertEq(loan.paymentsRemaining(), totalPayments);
    }

    
}