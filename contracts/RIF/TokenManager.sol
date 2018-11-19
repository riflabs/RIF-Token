pragma solidity ^0.4.24;

import "../third-party/openzeppelin/ownership/Ownable.sol";
import "../third-party/openzeppelin/math/SafeMath.sol";
import "./LockupAccount.sol";
import "./PreSale.sol";
import "./RIFToken.sol";

// This contract manages the Presale. It receives payment notifications from RIFNotaryBridge and creates the tokens
// accordingly.
contract TokenManager is Ownable {
    using SafeMath for uint256;
    using SafeMath for uint;

    // *****************
    // *** Constants ***
    // *****************
    uint constant TOTAL_BONUS_STAGES = 3;
    address constant NO_ESCROW = 0x00; // Address used for no escrow token distributions

    // Months are approximate: 730 hours = 30.416667 days/month avg for a 365 day year.
    // The uint is in seconds.
    uint constant MONTH_TIME = 730 hours;

    // 6 months cliff and 48 monthly installments.
    uint256 constant SHAREHOLDER_INITIAL_INSTALLMENTS = 0;
    uint256 constant SHAREHOLDER_CLIFF = 6;
    uint256 constant SHAREHOLDER_INSTALLMENTS = 42;
    uint256 constant SHAREHOLDER_INSTALLMENT_DURATION = MONTH_TIME;
    uint256 constant SHAREHOLDER_RECOVERY_TIME = 6*MONTH_TIME;

    address constant SHAREHOLDER_NO_BENEFICIARY = address(0);
    bytes32 constant SHAREHOLDER_HASH = keccak256("shareholder");

    // no cliff and 60 monthly installments.
    uint256 constant RIFLABS_INITIAL_INSTALLMENTS = 1;
    uint256 constant RIFLABS_CLIFF = 0;
    uint256 constant RIFLABS_INSTALLMENTS = 59;
    uint256 constant RIFLABS_INSTALLMENT_DURATION = MONTH_TIME;
    uint256 constant RIFLABS_RECOVERY_TIME = 0; // Unused since beneficiary is always set

    // Recovering of unused funds is only open a year after the original token
    // distribution
    uint256 constant RECOVER_UNUSED_FUNDS_TIME = 365 days;

    // The distribution time is set into the future to allow for the the iterative
    // process to finish
    uint constant DISTRIBUTION_TIME_EXTENSION = 2 hours;

    // *************
    // *** State ***
    // *************
    RIFToken token;
    PreSale presale;
    uint public tokenDistributionTime;
    bool distributedTokens;
    TokenDistribution[] public tokenDistributions;
    uint public bonusContributorIndex;
    uint public bonusCurrentStage;
    uint public contributorRecoveryIndex;
    uint public shareholderRecoveryIndex;
    uint public distributedShareholders;
    bool public hasDistributedRifLabs;
    uint public distributedContributors;
    uint contributorsSize;
    uint shareholdersSize;

    // ***************
    // *** Structs ***
    // ***************
    struct TokenDistribution {
        address beneficiary;
        address escrow;
        uint amount;
        string kind;
    }

    constructor (address aTokenAddress, address presaleAddress) public {
        require(aTokenAddress != 0x0);
        // The token contract
        token = RIFToken(aTokenAddress);

        require(presaleAddress != 0x0);
        // The PreSale data
        presale = PreSale(presaleAddress);

        // We haven't yet done any token distribution
        distributedTokens = false;
        distributedShareholders = 0;
        hasDistributedRifLabs = false;
        distributedContributors = 0;

        // For the bonus distribution
        tokenDistributionTime = 0;
        bonusCurrentStage = 0;
        bonusContributorIndex = 0;

        // For non-redeemed contributor funds recovery
        contributorRecoveryIndex = 0;

        // For non-beneficiary shareholder funds recovery
        shareholderRecoveryIndex = 0;

        contributorsSize = presale.getContributorsSize();
        shareholdersSize = presale.getShareholdersSize();
    }

    ////////////////////////////////////
    /// INITIAL TOKEN DISTRIBUTION
    ///////////////////////////////////

    function hasDistributed() public view returns (bool) {
        return distributedTokens;
    }

    function stillDistributing() public view returns(bool) {
        return
            distributedShareholders < shareholdersSize ||
            !hasDistributedRifLabs ||
            distributedContributors < contributorsSize;
    }

    function distributeTokens(uint256 _minGasForLoop) public {
        require(!distributedTokens);

        bool looped = false;

        while (stillDistributing() && gasleft() >= _minGasForLoop) {
            if (!hasDistributedRifLabs) {
                // We set the token distribution time
                // when the first actual distribution
                // takes place
                tokenDistributionTime = now + DISTRIBUTION_TIME_EXTENSION;
                distributeToRIFLabs();
            } else if (distributedShareholders < shareholdersSize) {
                distributeToShareholders(_minGasForLoop);
            } else if (distributedContributors < contributorsSize) {
                distributeToContributors(_minGasForLoop);
            }

            looped = true;
        }

        // We revert the transaction if no distribution actually took place
        if (!looped) {
            revert();
        }

        if (!stillDistributing()) {
            token.closeTokenDistribution(tokenDistributionTime);
            distributedTokens = true;
        }
    }

    function distributeToRIFLabs() private {
        (address beneficiary, uint amount) = presale.getRifLabs();

        // The RIF labs address will have its total amount transferred to an
        // intermediate vesting wallet, which will in turn handle the
        // vesting logic. We create this vesting wallet here.
        LockupAccount vesting = new LockupAccount(
            address(token),
            beneficiary,
            tokenDistributionTime,
            RIFLABS_INITIAL_INSTALLMENTS,
            RIFLABS_CLIFF,
            RIFLABS_INSTALLMENTS,
            RIFLABS_INSTALLMENT_DURATION,
            RIFLABS_RECOVERY_TIME
        );

        // Transfer the tokens to the escrow contract
        token.transferToShareholder(address(vesting), amount);

        // Add this distribution to the distribution list
        tokenDistributions.push(TokenDistribution({
            beneficiary: beneficiary,
            escrow: address(vesting),
            amount: amount,
            kind: "riflabs"
        }));

        hasDistributedRifLabs = true;
    }

    function distributeToShareholders(uint256 _minGasForLoop) private {
        // Each shareholder address will have its total amount transferred to an
        // intermediate vesting wallet, which will in turn handle the
        // vesting logic. We create each of these vesting wallets here.
        while (distributedShareholders < shareholdersSize && gasleft() >= _minGasForLoop) {
            (address beneficiary, uint amount) = presale.getShareholderAt(distributedShareholders);
            // Create the vesting contract
            LockupAccount vesting = new LockupAccount(
                address(token),
                beneficiary,
                tokenDistributionTime,
                SHAREHOLDER_INITIAL_INSTALLMENTS,
                SHAREHOLDER_CLIFF,
                SHAREHOLDER_INSTALLMENTS,
                SHAREHOLDER_INSTALLMENT_DURATION,
                SHAREHOLDER_RECOVERY_TIME
            );

            // Transfer the tokens to the vesting contract
            token.transferToShareholder(address(vesting), amount);

            // Add this distribution to the distribution list
            tokenDistributions.push(TokenDistribution({
                beneficiary: beneficiary,
                escrow: address(vesting),
                amount: amount,
                kind: "shareholder"
            }));

            distributedShareholders++;
        }
    }

    function distributeToContributors(uint256 _minGasForLoop) private {
        while (distributedContributors < contributorsSize && gasleft() >= _minGasForLoop){
            // There is no intermediate wallet for contributors
            (address beneficiary, uint amount) = presale.getContributorAt(distributedContributors);
            // Transfer the tokens to the contributor address
            token.transferToContributor(beneficiary, amount);

            // Add this distribution to the distribution list
            tokenDistributions.push(TokenDistribution({
                beneficiary: beneficiary,
                escrow: NO_ESCROW,
                amount: amount,
                kind: "contributor"
            }));

            distributedContributors++;
        }
    }

    // This method looks first for a matching distribution to a shareholder with
    // the given amount and no beneficiary set. If found, it calls the
    // LockupAccount.setBeneficiary method on the lockup contract with
    // the given wallet address, and then updates the corresponding distribution.
    // If not found, it reverts. It will also revert if the lockup account
    // has gone past its recovery time.
    function setShareholderAddress(uint256 amount, address wallet) public onlyOwner {
        require(wallet != SHAREHOLDER_NO_BENEFICIARY);
        require(hasDistributed());
        require(!token.isOriginalOrRedeemedContributor(wallet));

        uint matchIndex;
        bool found = false;

        for (uint i = 0; i < tokenDistributions.length; i++) {
            if (isNoBeneficiaryShareholder(tokenDistributions[i]) &&
                tokenDistributions[i].amount == amount) {

                matchIndex = i;
                found = true;
                break;
            }
        }

        require(found);

        LockupAccount lockup = LockupAccount(tokenDistributions[matchIndex].escrow);

        lockup.setBeneficiary(wallet); // This could revert depending on block time

        tokenDistributions[matchIndex].beneficiary = wallet;
    }

    // Try to recover all shareholder funds that haven't been assigned a beneficiary
    // This is possible considering that the recovery time for all shareholders lockup
    // accounts is the same. If recovery time hasn't gone by, first attempt at
    // a recover on a lockup will revert.
    function recoverNoBeneficiaryShareholders(uint256 _minGasForLoop) public {
        require(_minGasForLoop>0);
        require(shareholderRecoveryIndex < tokenDistributions.length);
        require(gasleft() >= _minGasForLoop);

        while (shareholderRecoveryIndex < tokenDistributions.length) {

            TokenDistribution storage tokenDistribution = tokenDistributions[shareholderRecoveryIndex];

            if (isNoBeneficiaryShareholder(tokenDistribution)) {
                LockupAccount lockup = LockupAccount(tokenDistribution.escrow);
                lockup.recover();
                tokenDistribution.beneficiary = address(this);
            }

            shareholderRecoveryIndex++;

            if (gasleft() < _minGasForLoop) return;
        }
    }

    function isNoBeneficiaryShareholder(TokenDistribution distribution) private pure returns (bool) {
        return  keccak256(abi.encodePacked(distribution.kind)) == SHAREHOLDER_HASH && // can't compare strings in solidity atm
                distribution.beneficiary == SHAREHOLDER_NO_BENEFICIARY;
    }

    // All contributor accounts that after 1 year have not been claimed are transferred to
    // RIFLabs. Also, all unpaid bonus (i.e., any left balance in this contract) and
    // all potential funds recovered from unspecified shareholder wallets is also
    // transferred to RIFLabs.
    // Once all contributors have been recovered and bonuses have been paid,
    // there's no longer need for any special interaction between the RIFToken
    // and the TokenManager. Thus, the relation is explicitly disabled.
    function recoverUnusedFunds(uint256 _minGasForLoop) public {
        require(tokenDistributionTime>0);
        require(bonusCurrentStage>=TOTAL_BONUS_STAGES);
        require(_minGasForLoop>0);

        uint deadline = tokenDistributionTime+RECOVER_UNUSED_FUNDS_TIME;
        require(now>=deadline);

        require(gasleft() >= _minGasForLoop);

        (address rifLabsAddress, ) = presale.getRifLabs();

        if (token.enableManagerContract()) {
            // Recover any non-redeemed funds from contributors
            // Pick up from where we left off
            while (contributorRecoveryIndex < contributorsSize) {
                (address contributorAddress, ) = presale.getContributorAt(contributorRecoveryIndex);
                if (!token.isRedeemed(contributorAddress)) {
                    token.delegate(contributorAddress, rifLabsAddress);
                }
                contributorRecoveryIndex++;
                if (gasleft() < _minGasForLoop) return; // only continue if there is enough gas for a loop
            }

            // Disable TokenManager-RIFToken special relationship
            token.disableManagerContract();
        }

        // Recover unused balance from this contract
        uint unusedBalance = token.balanceOf(address(this));
        if (unusedBalance > 0) {
            token.transfer(rifLabsAddress, unusedBalance);
        }
    }

    ////////////////////////////////////
    // BONUS PAYMENT
    // Anyone can call PayBonus, and pay bonuses for all RIF holders. However bonuses
    // are only freed at specific dates.
    ////////////////////////////////////
    function payBonus(uint256 _minGasForLoop) public {
        require(tokenDistributionTime>0);
        require(_minGasForLoop>0);
        require(bonusCurrentStage<TOTAL_BONUS_STAGES);

        uint deadline = tokenDistributionTime + getStageTime(bonusCurrentStage);

        // Check that the deadline for the bonus payment has been reached
        require(now>=deadline);
        require(gasleft() >= _minGasForLoop);

        while (bonusContributorIndex < contributorsSize && gasleft() >= _minGasForLoop) {
            // Payments to contributors are redirected by the RIFToken contract
            // to the new addresses, but here we can just send to the old
            // addresses.
            (address contributorAddress, ) = presale.getContributorAt(bonusContributorIndex);

            // getMinimumLeftFromSale() handles redirection
            uint investedRemaining = token.getMinimumLeftFromSale(contributorAddress);
            if (investedRemaining>0) {
                uint toPay = investedRemaining*getStageBonus(bonusCurrentStage)/100;
                require(token.transferBonus(contributorAddress, toPay)); // this should not fail
            }

            bonusContributorIndex++;
        }

        if (bonusContributorIndex >= contributorsSize) {
            // Payment finished. Move to next stage.
            bonusCurrentStage++;
            bonusContributorIndex = 0;
        }
    }

    // Direct Pre-sale bonuses are:
    // 20% for keeping the tokens for 3 months
    // 5% additional for 6 months
    // 5% additional for 9 months
    function getStageBonus(uint astage) private pure returns(uint) {
        if (astage==0) return 20;
        return 5;
    }

    function getStageTime(uint astage) private pure returns(uint) {
        if (astage==0) return (3*MONTH_TIME);
        if (astage==1) return (6*MONTH_TIME);
        //(astage==2), returns the upper bound time of the bonus stage
        return (9*MONTH_TIME);
    }
}
