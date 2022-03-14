//SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "./Authorizable.sol";
import "./HigherDimensions.sol";
import "./Wise.sol";

import "hardhat/console.sol";

contract DMT is ERC20, Authorizable {
    using SafeMath for uint256;

    uint256 public MAX_DMT_SUPPLY = 32000000000000000000000000000;
    string private TOKEN_NAME = "HD DMT";
    string private TOKEN_SYMBOL = "DMT";

    address public HD_CONTRACT;
    address public WISE_CONTRACT;

    uint256 public BOOSTER_MULTIPLIER = 1;
    uint256 public DMT_FARMING_FACTOR = 3; // wise to dmt ratio
    uint256 public DMT_SWAP_FACTOR = 12; // swap wise for dmt ratio

    // Moved "SKIP_COOLDOWN_BASE" to Wise contract
    // Moved "SKIP_COOLDOWN_BASE_FACTOR" to Wise contract

    // dmt mint event
    event Minted(address owner, uint256 numberOfDmt);
    event Burned(address owner, uint256 numberOfDmt);
    event WiseSwap(address owner, uint256 numberOfDmt);
    // wise event
    event MintedWise(address owner, uint256 numberOfDmt);
    event BurnedWise(address owner, uint256 numberOfWise);
    event StakedWise(address owner, uint256 numberOfWise);
    event UnstakedWise(address owner, uint256 numberOfWise);

    // Wise staking
    struct WiseStake {
        // user wallet - who we have to pay back for the staked wise.
        address user;
        // used to calculate how much dmt since.
        uint32 since;
        // amount of wises that have been staked.
        uint256 amount;
    }

    mapping(address => WiseStake) public wiseStakeHolders;
    uint256 public totalWiseStaked;
    address[] public _allWiseStakeHolders;
    mapping(address => uint256) private _allWiseStakeHoldersIndex;

    // wise stake and unstake
    event WiseStaked(address user, uint256 amount);
    event WiseUnStaked(address user, uint256 amount);

    constructor(address _hdContract, address _wiseContract)
        ERC20(TOKEN_NAME, TOKEN_SYMBOL)
    {
        HD_CONTRACT = _hdContract;
        WISE_CONTRACT = _wiseContract;
    }

    /**
     * pdates user's amount of staked wises to the given value. Resets the "since" timestamp.
     */
    function _upsertWiseStaking(
        address user,
        uint256 amount
    ) internal {
        // NOTE does this ever happen?
        require(user != address(0), "EMPTY ADDRESS");
        WiseStake memory wise = wiseStakeHolders[user];

        // if first time user is staking $wise...
        if (wise.user == address(0)) {
            // add tracker for first time staker
            _allWiseStakeHoldersIndex[user] = _allWiseStakeHolders.length;
            _allWiseStakeHolders.push(user);
        }
        // since its an upsert, we took out old wise and add new amount
        uint256 previousWise = wise.amount;
        // update stake
        wise.user = user;
        wise.amount = amount;
        wise.since = uint32(block.timestamp);

        wiseStakeHolders[user] = wise;
        totalWiseStaked = totalWiseStaked - previousWise + amount;
        emit WiseStaked(user, amount);
    }

    function staking(uint256 amount) external {
        require(amount > 0, "NEED WISE");
        Wise wiseContract = Wise(WISE_CONTRACT);
        uint256 available = wiseContract.balanceOf(msg.sender);
        require(available >= amount, "NOT ENOUGH WISE");
        WiseStake memory existingWise = wiseStakeHolders[msg.sender];
        if (existingWise.amount > 0) {
            // already have previous wise staked
            // need to calculate claimable
            uint256 projection = claimableView(msg.sender);
            // mint dmt to wallet
            _mint(msg.sender, projection);
            emit Minted(msg.sender, amount);
            _upsertWiseStaking(msg.sender, existingWise.amount + amount);
        } else {
            // no wise staked just update staking
            _upsertWiseStaking(msg.sender, amount);
        }
        wiseContract.burnWise(msg.sender, amount);
        emit StakedWise(msg.sender, amount);
    }

    /**
     * Calculates how much dmt is available to claim.
     */
    function claimableView(address user) public view returns (uint256) {
        WiseStake memory wise = wiseStakeHolders[user];
        require(wise.user != address(0), "NOT STAKED");
        // need to add 10000000000 to factor for decimal
        return
            ((wise.amount * DMT_FARMING_FACTOR) *
                (((block.timestamp - wise.since) * 10000000000) / 86400) *
                BOOSTER_MULTIPLIER) /
            10000000000;
    }

    // NOTE withdrawing wise without claiming dmt
    function withdrawWise(uint256 amount) external {
        require(amount > 0, "MUST BE MORE THAN 0");
        WiseStake memory wise = wiseStakeHolders[msg.sender];
        require(wise.user != address(0), "NOT STAKED");
        require(amount <= wise.amount, "OVERDRAWN");
        Wise wiseContract = Wise(WISE_CONTRACT);
        // uint256 projection = claimableView(msg.sender);
        _upsertWiseStaking(msg.sender, wise.amount - amount);
        // Need to burn 1/12 when withdrawing (breakage fee)
        uint256 afterBurned = (amount * 11) / 12;
        // mint wise to return to user
        wiseContract.mintWise(msg.sender, afterBurned);
        emit UnstakedWise(msg.sender, afterBurned);
    }

    /**
     * Claims dmt from staked Wise
     */
    function claimDmt() external {
        uint256 projection = claimableView(msg.sender);
        require(projection > 0, "NO DMT TO CLAIM");

        WiseStake memory wise = wiseStakeHolders[msg.sender];

        // Updates user's amount of staked wises to the given value. Resets the "since" timestamp.
        _upsertWiseStaking(msg.sender, wise.amount);

        // check: that the total Dmt supply hasn't been exceeded.
        _mintDmt(msg.sender, projection);
    }

    /**
     */
    function _removeUserFromWiseEnumeration(address user) private {
        uint256 lastUserIndex = _allWiseStakeHolders.length - 1;
        uint256 currentUserIndex = _allWiseStakeHoldersIndex[user];

        address lastUser = _allWiseStakeHolders[lastUserIndex];

        _allWiseStakeHolders[currentUserIndex] = lastUser; // Move the last token to the slot of the to-delete token
        _allWiseStakeHoldersIndex[lastUser] = currentUserIndex; // Update the moved token's index

        // This also deletes the contents at the last position of the array
        delete _allWiseStakeHoldersIndex[user];
        _allWiseStakeHolders.pop();
    }

    /**
     * Unstakes the wises, returns the Wise (mints) to the user.
     */
    function withdrawAllWiseAndClaimDmt() external {
        WiseStake memory wise = wiseStakeHolders[msg.sender];

        // NOTE does this ever happen?
        require(wise.user != address(0), "NOT STAKED");

        // if there's dmt to claim, supply it to the owner...
        uint256 projection = claimableView(msg.sender);
        if (projection > 0) {
            // supply dmt to the sender...
            _mintDmt(msg.sender, projection);
        }
        // if there's wise to withdraw, supply it to the owner...
        if (wise.amount > 0) {
            // mint wise to return to user
            // Need to burn 1/12 when withdrawing (breakage fee)
            uint256 afterBurned = (wise.amount * 11) / 12;
            Wise wiseContract = Wise(WISE_CONTRACT);
            wiseContract.mintWise(msg.sender, afterBurned);
            emit UnstakedWise(msg.sender, afterBurned);
        }
        // Internal: removes wise from storage.
        _unstakingWise(msg.sender);
    }

    /**
     * Internal: removes wise from storage.
     */
    function _unstakingWise(address user) internal {
        WiseStake memory wise = wiseStakeHolders[user];
        // NOTE when whould address be zero?
        require(wise.user != address(0), "EMPTY ADDRESS");
        totalWiseStaked = totalWiseStaked - wise.amount;
        _removeUserFromWiseEnumeration(user);
        delete wiseStakeHolders[user];
        emit WiseUnStaked(user, wise.amount);
    }

    /**
     * Dmts the hd the amount of Dmt.
     */
    function dmtHd(uint256 hdId, uint256 amount) external {
        // check: amount is gt zero...
        require(amount > 0, "MUST BE MORE THAN 0 DMT");

        IERC721 instance = IERC721(HD_CONTRACT);

        // check: msg.sender is hd owner...
        require(instance.ownerOf(hdId) == msg.sender, "NOT OWNER");
        
        // check: user has enough dmt in wallet...
        require(balanceOf(msg.sender) >= amount, "NOT ENOUGH DMT");
        
        // TODO should this be moved to wise contract? or does the order here, matter?
        Wise wiseContract = Wise(WISE_CONTRACT);
        (uint24 kg, , , , ) = wiseContract.stakedHd(hdId);
        require(kg > 0, "NOT STAKED");

        // burn dmt...
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);

        // update eatenAmount in Wise contract...
        wiseContract.dmtHd(hdId, amount);
    }

    // Moved "levelup" to the Wise contract - it doesn't need anything from Dmt contract.

    // Moved "skipCoolingOff" to the Wise contract - it doesn't need anything from Dmt contract.

    function swapWiseForDmt(uint256 wiseAmt) external {
        require(wiseAmt > 0, "MUST BE MORE THAN 0 WISE");

        // burn wises...
        Wise wiseContract = Wise(WISE_CONTRACT);
        wiseContract.burnWise(msg.sender, wiseAmt);

        // supply dmt...
        _mint(msg.sender, wiseAmt * DMT_SWAP_FACTOR);
        emit WiseSwap(msg.sender, wiseAmt * DMT_SWAP_FACTOR);
    }

    /**
     * Internal: mints the dmt to the given wallet.
     */
    function _mintDmt(address sender, uint256 dmtAmount) internal {
        // check: that the total Dmt supply hasn't been exceeded.
        require(totalSupply() + dmtAmount < MAX_DMT_SUPPLY, "OVER MAX SUPPLY");
        _mint(sender, dmtAmount);
        emit Minted(sender, dmtAmount);
    }

    // ADMIN FUNCTIONS

    /**
     * Admin : mints the dmt to the given wallet.
     */
    function mintDmt(address sender, uint256 amount) external onlyOwner {
        _mintDmt(sender, amount);
    }

    /**
     * Admin : used for temporarily multipling how much dmt is distributed per staked wise.
     */
    function updateBoosterMultiplier(uint256 _value) external onlyOwner {
        BOOSTER_MULTIPLIER = _value;
    }

    /**
     * Admin : updates how much dmt you get per staked wise (e.g. 3x).
     */
    function updateFarmingFactor(uint256 _value) external onlyOwner {
        DMT_FARMING_FACTOR = _value;
    }

    /**
     * Admin : updates the multiplier for swapping (burning) wise for dmt (e.g. 12x).
     */
    function updateDmtSwapFactor(uint256 _value) external onlyOwner {
        DMT_SWAP_FACTOR = _value;
    }

    /**
     * Admin : updates the maximum available dmt supply.
     */
    function updateMaxDmtSupply(uint256 _value) external onlyOwner {
        MAX_DMT_SUPPLY = _value;
    }

    /**
     * Admin : util for working out how many people are staked.
     */
    function totalWiseHolder() public view returns (uint256) {
        return _allWiseStakeHolders.length;
    }

    /**
     * Admin : gets the wallet for the the given index. Used for rebalancing.
     */
    function getWiseHolderByIndex(uint256 index) internal view returns (address){
        return _allWiseStakeHolders[index];
    }

    /**
     * Admin : Rebalances the pool. Mint to the user's wallet. Only called if changing multiplier.
     */
    function rebalanceStakingPool(uint256 from, uint256 to) external onlyOwner {
        // for each holder of staked Wise...
        for (uint256 i = from; i <= to; i++) {
            address holderAddress = getWiseHolderByIndex(i);

            // check how much dmt is claimable...
            uint256 pendingClaim = claimableView(holderAddress);
            WiseStake memory wise = wiseStakeHolders[holderAddress];

            // supply Dmt to the owner's wallet...
            _mint(holderAddress, pendingClaim);
            emit Minted(holderAddress, pendingClaim);

            // pdates user's amount of staked wises to the given value. Resets the "since" timestamp.
            _upsertWiseStaking(holderAddress, wise.amount);
        }
    }
}
