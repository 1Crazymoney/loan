// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.7;

import { Loan }  from "../../Loan.sol";

contract MockLoan is Loan {

    constructor(address _borrower, address[2] memory _assets, uint256[6] memory _parameters, uint256[2] memory _requests) {
        _initialize(_borrower, _assets, _parameters, _requests);
    }

}
