/* solium-disable security/no-block-members */

pragma solidity ^0.4.24;

import "../third-party/openzeppelin/token/ERC20/ERC20Basic.sol";
import "../third-party/openzeppelin/token/ERC20/SafeERC20.sol";
import "../third-party/openzeppelin/ownership/Ownable.sol";
import "../third-party/openzeppelin/math/SafeMath.sol";

/**
* @title LockupAccount
* @dev A token holder contract that can release its token balance in several installments,
* with an (optional) cliff and (optional) initial payments, both measured also in installments.
* The creator also indicates the duration of each installment in seconds. The total duration of
* the vesting period is then calculated as (initial installments + cliff + installments) * installmentDuration.
* For simplicity, this contract supports release from a single token contract.
*
* This is based on openzeppelin's TokenVesting
* (see https://github.com/OpenZeppelin/openzeppelin-solidity/blob/v1.12.0/contracts/token/ERC20/TokenVesting.sol).
*/
contract LockupAccount is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for ERC20Basic;

    event Released(uint256 amount);

    // Used when no beneficiary set
    address constant NO_BENEFICIARY = address(0);

    // the token contract
    ERC20Basic public token;

    // beneficiary of tokens after they are released
    address public beneficiary;

    // cliff and installments parameters
    uint256 public start;
    uint256 public end;
    uint256 public initialInstallments;
    uint256 public cliff;
    uint256 public cliffEnd;
    uint256 public installments;
    uint256 public installmentDuration;
    uint256 public recoveryTime;

    uint256 public released;

    /**
    * @dev Creates a vesting contract that vests its balance of any ERC20 token to the
    * _beneficiary, gradually in a linear fashion until _start + _duration. By then all
    * of the balance will have vested.
    * @param _tokenAddress address of the token contract
    * @param _beneficiary address of the beneficiary to whom vested tokens are transferred (optional)
    * @param _start the time (as Unix time) at which point vesting starts
    * @param _initialInstallments the number of installments vested from the start
    * @param _cliff duration in installments of the cliff in which tokens will begin to vest
    * @param _installments total number of installments post-cliff period
    * @param _installmentDuration duration in seconds of each installment
    * @param _recoveryTime time in seconds after _start from which tokens can be recovered by the owner
    */
    constructor(
        address _tokenAddress,
        address _beneficiary,
        uint256 _start,
        uint256 _initialInstallments,
        uint256 _cliff,
        uint256 _installments,
        uint256 _installmentDuration,
        uint256 _recoveryTime
    )
    public
    {
        require(_tokenAddress != address(0));
        require(_installments > 0);
        require(_installmentDuration > 0);

        token = ERC20Basic(_tokenAddress);
        beneficiary = _beneficiary;

        start = _start;
        end = start.add(_cliff.add(_installments).mul(_installmentDuration));

        initialInstallments = _initialInstallments;

        cliff = _cliff;
        cliffEnd = start.add(_cliff.mul(_installmentDuration));

        installments = _installments;
        installmentDuration = _installmentDuration;

        recoveryTime = _recoveryTime;

        released = 0;
    }

    /**
    * @notice Sets the beneficiary if not set and not past recovery time
    */
    function setBeneficiary(address _beneficiary) public onlyOwner {
        require(beneficiary == NO_BENEFICIARY);

        uint deadline = start.add(recoveryTime);
        require(now < deadline);

        beneficiary = _beneficiary;
    }

    /**
    * @notice Sets the beneficiary to the owner if not set and enough
    * time has passed.
    */
    function recover() public {
        require(beneficiary == NO_BENEFICIARY);

        uint deadline = start.add(recoveryTime);
        require(now >= deadline);

        beneficiary = owner;
    }

    /**
    * @notice Transfers vested tokens to beneficiary.
    */
    function release() public {
        require(beneficiary != NO_BENEFICIARY);

        uint256 unreleased = releasableAmount();

        require(unreleased > 0);

        released = released.add(unreleased);

        token.safeTransfer(beneficiary, unreleased);

        emit Released(unreleased);
    }

    /**
    * @dev Calculates the amount that has already vested but hasn't been released yet.
    */
    function releasableAmount() public view returns (uint256) {
        return vestedAmount().sub(released);
    }

    /**
    * @dev Calculates the amount that has already vested.
    */
    function vestedAmount() public view returns (uint256) {
        uint256 currentBalance = token.balanceOf(address(this));
        uint256 totalBalance = currentBalance.add(released);

        // Total # of installments is calculated as:
        // # of initial installments +
        // # of cliff installments +
        // # of post-cliff installments (or just "installments")
        // Therefore, installment amount is calculated as the total balance divided
        // by the sum of these three figures.
        uint256 installmentAmount = totalBalance.div(initialInstallments.add(cliff.add(installments)));

        if (now < cliffEnd) { // before cliff period end
            // Vested amount is #initial-installments
            return initialInstallments.mul(installmentAmount);
        } else if (now >= end) { // after end of total vesting period
            return totalBalance;
        } else {
            // After the cliff period, an amount proportional to the number of installments
            // of the cliff is vested at once.
            // So, vested is #initial-installments + #cliff-installments + #installments payable after cliff
            // times the amount for each installment.
            return initialInstallments.add(cliff).add(
                now.sub(cliffEnd).div(installmentDuration) // #installments payable after cliff (division truncates)
            ).mul(installmentAmount);
        }
    }
}
