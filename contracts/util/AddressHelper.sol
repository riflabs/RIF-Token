pragma solidity ^0.4.24;

library AddressHelper {
    function recoverAddress(bytes32 hash, uint8 v, bytes32 r, bytes32 s) public pure
        returns (address) {
        // Version of signature should be 27 or 28, but 0 and 1 are also possible versions
        uint8 vv = v;
        if (vv < 27) {
            vv += 27;
        }

        // If the version is correct return the signer address
        if (vv != 27 && vv != 28) {
            return (address(0));
        } else {
            return ecrecover(hash, vv, r, s);
        }

    }

    function char(byte b) public pure returns (byte c) {
        if (b < 10) return byte(uint8(b) + 0x30);
        else return byte(uint8(b) + 0x57);
    }

    function getHashedPublicKey(
        bytes32 _xPoint,
        bytes32 _yPoint)
        pure public
        returns(
            bytes20 hashedPubKey)
    {
        byte startingByte = 0x04;
        return ripemd160(abi.encodePacked(sha256(abi.encodePacked(startingByte, _xPoint, _yPoint))));
    }

    function fromHexChar(uint c) public pure returns (uint) {
        if (c >= uint(byte('0')) && c <= uint(byte('9'))) {
            return c - uint(byte('0'));
        }

        if (c >= uint(byte('a')) && c <= uint(byte('f'))) {
            return 10 + c - uint(byte('a'));
        }

        if (c >= uint(byte('A')) && c <= uint(byte('F'))) {
            return 10 + c - uint(byte('A'));
        }

        // Reaching this point means the ordinal is not for a hex char.
        revert();
    }

    function fromAsciiString(string s) public pure returns(address) {
        bytes memory ss = bytes(s);

        // it should have 40 or 42 characters
        if (ss.length != 40 && ss.length != 42) revert();

        uint r = 0;
        uint offset = 0;

        if (ss.length == 42) {
            offset = 2;

            if (ss[0] != byte('0')) revert();
            if (ss[1] != byte('x') && ss[1] != byte('X')) revert();
        }

        uint i;
        uint x;
        uint v;

        // loads first 32 bytes from array,
        // skipping array length (32 bytes to skip)
        // offset == 0x20
        assembly { v := mload(add(0x20, ss)) }

        // converts the first 32 bytes, adding to result
        for (i = offset; i < 32; ++i) {
            assembly { x := byte(i, v) }
            r = r * 16 + fromHexChar(x);
        }

        // loads second 32 bytes from array,
        // skipping array length (32 bytes to skip)
        // and first 32 bytes
        // offset == 0x40
        assembly { v := mload(add(0x40, ss)) }

        // converts the last 8 bytes, adding to result
        for (i = 0; i < 8 + offset; ++i) {
            assembly { x := byte(i, v) }
            r = r * 16 + fromHexChar(x);
        }

        return address(r);
    }
}
