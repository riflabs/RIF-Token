pragma solidity ^0.4.24;

import "../third-party/openzeppelin/token/ERC20/StandardToken.sol";
import "../third-party/openzeppelin/token/ERC20/DetailedERC20.sol";
import "../third-party/openzeppelin/ownership/Ownable.sol";
import "../ERC677/ERC677TransferReceiver.sol";
import "./AddressLinker.sol";
import "../util/AddressHelper.sol";

contract RIFToken is DetailedERC20, Ownable, StandardToken {
    /**
     * Transfer event as described in ERC-677
     * See https://github.com/ethereum/EIPs/issues/677 for details
     */
    event Transfer(address indexed from, address indexed to, uint256 value, bytes data);

    mapping(address => uint) public minimumLeftFromSale;

    // is the account of the original contributor
    mapping(address => bool) public isInitialContributor;

    // redeemed to same account or to another account
    mapping(address => bool) public isRedeemed;

    // original or redeemed contributor addresses
    mapping (address => bool) public isOriginalOrRedeemedContributor;

    // redirect:
    // returns new address old address is now mapped
    mapping(address => address) public redirect;

    bool public enableManagerContract;
    address public authorizedManagerContract;

    uint public distributionTime;

    uint256 constant REDEEM_DEADLINE = 365 days;
    address constant ZERO_ADDRESS = address(0);

    // The RIF token has minimum ownership permissions until ownership is manually withdrawn by
    // releaseOwnership()

    constructor() DetailedERC20("RIF","RIF",18) public {
        // There will only ever be 1 billion tokens. Each tokens has 18 decimal digits.
        // Therefore, 1 billion = 1,000,000,000 = 10**9 followed by 18 more zeroes = 10**18
        // Total => 10**27 RIFIs.
        totalSupply_ = 10**27;
        balances[address(this)] = totalSupply_;
        enableManagerContract = false;
        authorizedManagerContract = ZERO_ADDRESS;
        distributionTime = 0;
    }

    function getMinimumLeftFromSale(address a) public view returns(uint) {
        address dest = getRedirectedAddress(a);
        return minimumLeftFromSale[dest];
    }

    function disableManagerContract() public onlyAuthorizedManagerContract {
        enableManagerContract = false;
    }

    function closeTokenDistribution(uint _distributionTime) public onlyAuthorizedManagerContract {
        require(distributionTime == 0);
        distributionTime = _distributionTime;
    }

    function setAuthorizedManagerContract(address authorized) public onlyOwner {
        require(authorizedManagerContract == ZERO_ADDRESS);
        authorizedManagerContract = authorized;
        enableManagerContract = true;
        transferAll(this, authorized);
    }

    modifier onlyAuthorizedManagerContract() {
        require(msg.sender==authorizedManagerContract);
        require(enableManagerContract);
        _;
    }

    modifier onlyWhileInDistribution() {
        require(distributionTime == 0);
        _;
    }

    modifier onlyAfterDistribution() {
        require(distributionTime > 0 && now >= distributionTime);
        _;
    }

    modifier onlyIfAddressUsable(address sender) {
        require(!isInitialContributor[sender] || isRedeemed[sender]);
        _;
    }

    // Important: this is an internal function. It doesn't verify transfer rights.
    function transferAll(address _from, address _to) internal returns (bool) {
        require(_to != ZERO_ADDRESS);

        uint256 _value;

        _value = balances[_from];
        balances[_from] = 0;
        balances[_to] = balances[_to].add(_value);

        emit Transfer(_from, _to, _value);

        return true;
    }

    function transferToShareholder(address wallet, uint amount) public onlyWhileInDistribution onlyAuthorizedManagerContract {
        bool result = super.transfer(wallet, amount);

        if (!result) revert();
    }

    // TokenManager is the owner of the tokens to the pre-sale contributors and will distribute them
    // also TokenManager is the owner of the bonuses.
    function transferToContributor(address contributor, uint256 amount) public onlyWhileInDistribution onlyAuthorizedManagerContract {
        if (!validAddress(contributor)) return;

        super.transfer(contributor, amount);

        minimumLeftFromSale[contributor] += amount; //sets the contributor as an ITA special address

        isInitialContributor[contributor] = true;
        isOriginalOrRedeemedContributor[contributor] = true;
    }

    // If this transfer fails, there will be a problem because other bonus won't be able to be paid.
    function transferBonus(address _to, uint256 _value) public onlyAuthorizedManagerContract returns (bool) {
        if (!isInitialContributor[_to]) return false;

        address finalAddress = getRedirectedAddress(_to);

        return super.transfer(finalAddress, _value);
    }

    function delegate(address from, address to) public onlyAuthorizedManagerContract returns (bool) {
        if (!isInitialContributor[from] || isRedeemed[from]) {
            return false;
        }

        if (!transferAll(from, to)) {
            return false;
        }

        // mark as redirected and redeemed, for informational purposes
        redirect[from] = to;
        isRedeemed[from] = true;

        return true;
    }

    function redeemIsAllowed() public view returns (bool) {
        return  distributionTime > 0 &&
                now >= distributionTime &&
                now <= distributionTime + REDEEM_DEADLINE;
    }

    function redeemToSameAddress() public returns (bool) {
        require(redeemIsAllowed());

        // Only an original contributor can be redeemed
        require(isInitialContributor[msg.sender]);

        isRedeemed[msg.sender] = true;
        
        return true;
    }

    // Important: the user should not use the same contributorAddress for two different chains.
    function redeem(
        address contributorAddress, uint chainId,
        string redeemAddressAsString, uint8 sig_v,
        bytes32 sig_r, bytes32 sig_s) public returns (bool) {

        require(redeemIsAllowed());

        // Only an original contributor can be redeemed
        require(isInitialContributor[contributorAddress]);

        // Avoid redeeming an already redeemed address
        require(!isRedeemed[contributorAddress]);

        address redeemAddress = AddressHelper.fromAsciiString(redeemAddressAsString);

        // Avoid reusing a contributor address
        require(!isOriginalOrRedeemedContributor[redeemAddress]);

        require(AddressLinker.acceptLinkedRskAddress(contributorAddress, chainId,
            redeemAddressAsString, sig_v, sig_r, sig_s));

        // Now we must move the funds from the old address to the new address
        minimumLeftFromSale[redeemAddress] = minimumLeftFromSale[contributorAddress];
        minimumLeftFromSale[contributorAddress] = 0;

        // Mark as redirected and redeemed
        redirect[contributorAddress] = redeemAddress;
        isRedeemed[contributorAddress] = true;
        isOriginalOrRedeemedContributor[redeemAddress] = true;

        // Once the contributorAddress has moved the funds to the new RSK address, what to do with the old address?
        // Users should not receive RIFs in the old address from other users. If they do, they may not be able to access
        // those RIFs.
        return transferAll(contributorAddress, redeemAddress);
    }

    function contingentRedeem(
        address contributorAddress,
        uint chainId,
        address redeemAddress, uint8 sig_v,
        bytes32 sig_r, bytes32 sig_s) public onlyOwner returns (bool) {

        require(redeemIsAllowed());

        // Only an original contributor can be redeemed
        require(isInitialContributor[contributorAddress]);

        // Avoid redeeming an already redeemed address
        require(!isRedeemed[contributorAddress]);

        // Avoid reusing a contributor address
        require(!isOriginalOrRedeemedContributor[redeemAddress]);

        if (!AddressLinker.acceptDelegate(contributorAddress, chainId, sig_v, sig_r, sig_s)) revert();

        // Now we must move the funds from the old address to the new address
        minimumLeftFromSale[redeemAddress] = minimumLeftFromSale[contributorAddress];
        minimumLeftFromSale[contributorAddress] = 0;

        // Mark as redirected and redeemed
        redirect[contributorAddress] = redeemAddress;
        isRedeemed[contributorAddress] = true;
        isOriginalOrRedeemedContributor[redeemAddress] = true;

        // Once the contributorAddress has moved the funds to the new RSK address, what to do with the old address?
        // Users should not receive RIFs in the old address from other users. If they do, they may not be able to access
        // those RIFs.
        return transferAll(contributorAddress, redeemAddress);
    }

    function getRedirectedAddress(address a) public view returns(address) {
        address r = redirect[a];

        if (r != ZERO_ADDRESS) {
            return r;
        }

        return a;
    }

    function validAddress(address a) public pure returns(bool) {
        return (a != ZERO_ADDRESS);
    }

    function wasRedirected(address a) public view returns(bool) {
        return (redirect[a] != ZERO_ADDRESS);
    }

    function transfer(address _to, uint256 _value) public onlyAfterDistribution onlyIfAddressUsable(msg.sender) returns (bool) {
        // cannot transfer to a redirected account
        if (wasRedirected(_to)) return false;

        bool result = super.transfer(_to, _value);

        if (!result) return false;

        doTrackMinimums(msg.sender);

        return true;
    }

    /**
     * ERC-677's only method implementation
     * See https://github.com/ethereum/EIPs/issues/677 for details
     */
    function transferAndCall(address _to, uint _value, bytes _data) public returns (bool) {
        bool result = transfer(_to, _value);
        if (!result) return false;

        emit Transfer(msg.sender, _to, _value, _data);

        ERC677TransferReceiver receiver = ERC677TransferReceiver(_to);
        receiver.tokenFallback(msg.sender, _value, _data);

        // IMPORTANT: the ERC-677 specification does not say
        // anything about the use of the receiver contract's
        // tokenFallback method return value. Given
        // its return type matches with this method's return
        // type, returning it could be a possibility.
        // We here take the more conservative approach and
        // ignore the return value, returning true
        // to signal a succesful transfer despite tokenFallback's
        // return value -- fact being tokens are transferred
        // in any case.
        return true;
    }

    function transferFrom(address _from, address _to, uint256 _value) public onlyAfterDistribution onlyIfAddressUsable(_from) returns (bool) {
        // cannot transfer to a redirected account
        if (wasRedirected(_to)) return false;

        bool result = super.transferFrom(_from, _to, _value);
        if (!result) return false;

        doTrackMinimums(_from);

        return true;
    }

    function approve(address _spender, uint256 _value) public onlyAfterDistribution onlyIfAddressUsable(msg.sender) returns (bool) {
        return super.approve(_spender, _value);
    }

    function increaseApproval(address _spender, uint256 _addedValue) public onlyAfterDistribution onlyIfAddressUsable(msg.sender) returns (bool) {
        return super.increaseApproval(_spender, _addedValue);
    }

    function decreaseApproval(address _spender, uint256 _subtractedValue) public onlyAfterDistribution onlyIfAddressUsable(msg.sender) returns (bool) {
        return super.decreaseApproval(_spender, _subtractedValue);
    }

    function doTrackMinimums(address addr) private {
        // We only track minimums while there's a manager
        // contract that can pay the bonuses for which
        // these minimums are tracked for in the first place.
        if (!enableManagerContract) return;

        uint m = minimumLeftFromSale[addr];

        if ((m>0) && (balances[addr] < m)) {
            minimumLeftFromSale[addr] = balances[addr];
        }
    }
}
