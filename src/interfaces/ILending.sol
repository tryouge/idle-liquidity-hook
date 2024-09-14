// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface ILending {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
}
