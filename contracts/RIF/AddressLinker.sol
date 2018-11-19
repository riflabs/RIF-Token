pragma solidity ^0.4.24;

import "../util/AddressHelper.sol";
import "../third-party/openzeppelin/math/SafeMath.sol";

library AddressLinker   {
    using SafeMath for uint256;
    using SafeMath for uint;

    uint constant BITCOIN  = 0;
    uint constant ETHEREUM = 1;

    function acceptLinkedRskAddress(
        address buyerAddress, uint chainId,
        string redeemAddressAsString, uint8 sig_v,
        bytes32 sig_r, bytes32 sig_s) public pure returns (bool) {

        // Verify signatures
        bytes32 hash;

        if (chainId == BITCOIN) {
            hash = sha256(abi.encodePacked(sha256(abi.encodePacked("\x18Bitcoin Signed Message:\n\x2a", redeemAddressAsString))));
        } else {
            hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n42", redeemAddressAsString));
        }

        address recoveredAddress = AddressHelper.recoverAddress(hash, sig_v, sig_r, sig_s);

        return recoveredAddress == address(buyerAddress);
    }

    function acceptDelegate(
        address buyerAddress, uint chainId,
        uint8 sig_v,
        bytes32 sig_r, bytes32 sig_s) public pure returns (bool) {

        // Verify signatures
        bytes32 hash;

        if (chainId==BITCOIN) {
            hash = sha256(abi.encodePacked(sha256(abi.encodePacked("\x18Bitcoin Signed Message:\n\x0a","DELEGATION"))));
        } else {
            hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n10","DELEGATION"));
        }

        address recoveredAddress = AddressHelper.recoverAddress(hash,sig_v,sig_r,sig_s);

        return recoveredAddress == address(buyerAddress);
    }
}
