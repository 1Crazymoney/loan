// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.7;

import { IMapleLoanEvents } from "./interfaces/IMapleLoan.sol";

import { MapleLoanInternals } from "./MapleLoanInternals.sol";

/// @title MapleLoanInitializer is intended to initialize the storage of a MapleLoan proxy.
contract MapleLoanInitializer is IMapleLoanEvents, MapleLoanInternals {

    function encodeArguments(
        address borrower_,
        address[2] memory assets_,
        uint256[6] memory parameters_,
        uint256[3] memory amounts_,
        uint256[4] memory fees_
    ) external pure returns (bytes memory encodedArguments_) {
        return abi.encode(borrower_, assets_, parameters_, amounts_, fees_);
    }

    function decodeArguments(bytes calldata encodedArguments_)
        public pure returns (
            address borrower_,
            address[2] memory assets_,
            uint256[6] memory parameters_,
            uint256[3] memory amounts_,
            uint256[4] memory fees_
        )
    {
        (
            borrower_,
            assets_,
            parameters_,
            amounts_,
            fees_
        ) = abi.decode(encodedArguments_, (address, address[2], uint256[6], uint256[3], uint256[4]));
    }

    fallback() external {
        (
            address borrower_,
            address[2] memory assets_,
            uint256[6] memory parameters_,
            uint256[3] memory amounts_,
            uint256[4] memory fees_
        ) = decodeArguments(msg.data);

        _initialize(borrower_, assets_, parameters_, amounts_, fees_);

        emit Initialized(borrower_, assets_, parameters_, amounts_, fees_);
    }

}
