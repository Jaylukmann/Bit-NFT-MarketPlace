// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

//Bit-NFT-Marketplace is a marketplace where you as a seller can list your erc721 tokens
//for sale either on cash and carry basis or on installmental basis.
//It is a platform where buyers can buy NFT in dribs and drabs.
//sellers sends their nft to the contract using its address and the tokenId where it is secured.
//At the end of the duration of the sale which is 40 days,the seller gets his ether while the buyer gets his NFT
//if the buyer defaults,he/she forfeits 10% of total ether sent(5% for the marketplace and 5% compensation to the seller)
//And the seller gets back his NFT while the buyer gets back his ether minus 10% of total.
//If it is an instant sale,the marketplace receive 5% of the NFT price otherwise all funds go to seller..

contract BitNFTMarketPlace is Ownable, IERC721Receiver {
    using Counters for Counters.Counter;
    //Deriving agreementId from Counters library
    Counters.Counter public agreementId;

     uint public immutable AGREEMENT_TIME; //40 days but 4 hours for testing

     //constructor
     constructor(){
        AGREEMENT_TIME =  4 hours;
    }
    //All events to be emitted
    event NewNFTListed(
        address nftContractAddress,
        uint256 nftTokenId,
        address indexed seller,
        uint256 price
    );

    event NftBought(
        uint256 nftTokenId,
        address indexed seller,
        address indexed buyer,
        uint256 price
    );

    event BitBuy(
        uint256 nftTokenId,
        address indexed seller,
        address buyer,
        uint256 price
        );

    event SellerClaim(
        uint256 nftTokenId, 
        address indexed seller);

    event BuyerClaim(
         uint256 nftTokenId,
         address indexed buyer
         );

    event AgreementEnded(
        uint256 nftTokenId,
        address indexed buyer,
        bool saleEnded
    );

    event Received(
        address sender, 
        uint256 amount, 
        string message
        );

    //Modelling the agreement
   struct Agreements {
        address nftContractAddress;
        uint nftTokenId;
        address seller;
        bool saleEnded;
        uint agreementEndAt;
        uint price;
        bool onBit;
        //map amount paid in bit to each bit buyer
     mapping( address => uint) bit;
    }
   //map from agreementId => seller => totalPayForSeller
     mapping( uint => mapping(address => uint)) public totalPayForSeller;

    //Map each agreement to its agreementId
    mapping(uint256 => Agreements) public agreements;

    modifier canListNFT(address _nftContractAddress, uint256 _nftTokenId) {
        require(
            IERC721(_nftContractAddress).ownerOf(_nftTokenId) == msg.sender,
            "You can only list only the NFT you own"
        );
        _;
    }
    modifier canBuyNow(uint256 _agreementId) {
        Agreements storage agreement = agreements[_agreementId];
        require(msg.sender != agreement.seller, "NFT owner cannot buy his NFT");
        require(
            msg.value == agreements[_agreementId].price ,
            "Value sent must be equal to NFT price"
        );
        require(
            agreements[_agreementId].onBit == false,
            "A buyer has partly paid for this token"
        );
        _;
    }
    
    modifier canBuyInBits(uint256 _agreementId,address _seller) {
        Agreements storage agreement = agreements[_agreementId];
        require(msg.sender != agreement.seller, "NFT owner cannot buy his NFT");
        require(
            totalPayForSeller[_agreementId][_seller] ==
                agreement.bit[msg.sender],
            "This NFT has already been partly paid for by another buyer"
        );
        require(
            block.timestamp < agreements[_agreementId].agreementEndAt,
            "agreement time has elapsed"
        );
        _;
    }
   
    modifier CanClaim(uint256 _agreementId) {
        Agreements storage agreement = agreements[_agreementId];
        require(
            agreements[_agreementId].saleEnded == true,
            "NFT Sale agreement has not ended yet"
        );
        require(
            block.timestamp >= agreements[_agreementId].agreementEndAt,
            "The agreement has not ended yet"
        );
        require(
                  agreement.bit[msg.sender] <= agreements[_agreementId].price,
                "total payment made"
        );
        _;
    }

    modifier agreementEnded(uint256 _agreementId) {
        Agreements storage agreement = agreements[_agreementId];
        require(
            agreement.saleEnded == true &&
                (block.timestamp >= agreements[_agreementId].agreementEndAt),
            "agreement duration has not ended"
        );
        _;
    }


    //ListToken function help list NFT with its token contract address,tokenId and a price.
    //NFT can be bought between now and the next 40 days otherwise, it has to be re-listed
    function listToken(
        address _nftContractAddress,
        uint256 _nftTokenId,
        uint256 _price
    )
        public
        payable
        canListNFT(_nftContractAddress, _nftTokenId)
        returns (uint256 _Id)
    {
        IERC721(_nftContractAddress).safeTransferFrom(
            msg.sender,
            address(this),
            _nftTokenId
        );
        uint256 currentId = agreementId.current();
        agreementId.increment();
        Agreements storage agreement = agreements[currentId];
        // update each property of the agreement struct
        agreement.nftContractAddress = _nftContractAddress;
        agreement.nftTokenId = _nftTokenId;
        agreement.seller = msg.sender;
        agreement.saleEnded = false;
        agreement.price = _price;
        agreement.onBit = false;
        //The real agreement time is for 40 days but for testing purpose,we use 4 hours
        agreement.agreementEndAt = block.timestamp + AGREEMENT_TIME;
        emit NewNFTListed(_nftContractAddress, _nftTokenId, msg.sender, _price);
        return currentId;
    }

    //buyNow function is called when the buyer wishes to pay all the ether requested by the seller
    function buyNow(address _nftContractAddress,
        uint256 _agreementId,
        uint256 _nftTokenId,
        address _seller
    ) public payable canBuyNow(_agreementId) returns (bool) {
        Agreements storage agreement = agreements[_agreementId];
        //calculate commission
       
        //Prevent re-entrancy attack
       agreement.price = 0;
       // ether  (amount= price minus contract commission) is sent from the buyer to the seller
        (bool done, ) = payable(_seller).call{value: (msg.value * 95)/100}(
            ""
        );
        require(done, "Cannot send ether to the seller");

        //Send contract commission in form of ether to the smart contract owner
        (bool etherSent, ) = payable(Ownable.owner()).call{
            value: (msg.value * 5)/100
        }("");
        require(etherSent, "Cannot send ether to the contract owner");

        //Smart contract sends nft to the buyer
        IERC721(_nftContractAddress).safeTransferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        agreements[_agreementId].onBit = false;
         agreements[_agreementId].saleEnded = true;
        emit NftBought(_nftTokenId, agreement.seller, msg.sender, agreement.price);
        return true;
    }
    function handlePayOut(
        address _nftContractAddress,
        uint256 _agreementId,
        uint256 _nftTokenId,
        address _seller
    )   public payable {
        Agreements storage agreement = agreements[_agreementId];
        
        //sends seller's balance minus  contractValue to the seller
        (bool isSent, ) = payable(_seller).call{value: (msg.value * 95)/100}("");
        require(isSent, "Cannot send ether to the seller");

        //sends smart contract owners commission
        (bool hasSent, ) = payable(Ownable.owner()).call{value: (msg.value * 5)/100}(
            ""
        );
        require(hasSent, "Cannot send ether to the seller");

        //sends NFT to the buyer
        IERC721(_nftContractAddress).safeTransferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        
        emit AgreementEnded(_nftTokenId, agreement.seller, agreement.saleEnded);
    }
    //BuyInBit function is called by buyers who intend to buy the NFT in installments.
    function buyInBit(
        address _nftContractAddress,
        uint256 _agreementId,
        uint256 _nftTokenId,
        address _seller
    )
        public
        payable
        canBuyInBits(_agreementId,_seller)
        returns (bool success)
    {
        Agreements storage agreement = agreements[_agreementId];

        //Send ether to the smart contract
        (bool isSent, ) = payable(address(this)).call{value: msg.value}("");
        require(isSent, "Cannot send ether to the contract");
        agreement.bit[msg.sender] += msg.value;
        totalPayForSeller[_agreementId][_seller] += msg.value;
    
        if (
            totalPayForSeller[_agreementId][_seller] ==
            agreements[_agreementId].price &&
            agreement.bit[msg.sender] == agreements[_agreementId].price 
            //block.timestamp >= agreements[_agreementId].agreementEndAt
        ) {
            handlePayOut( _nftContractAddress, _agreementId, _nftTokenId,_seller);
            emit AgreementEnded(_nftTokenId, msg.sender, agreement.saleEnded);
        } else
            emit BitBuy(
                _nftTokenId,
                agreement.seller,
                msg.sender,
                agreement.price
            );
        return (success);
    }

    

    //This function is used by the seller at the expiry of the installment agreement
    function sellerClaimNFT(
        address _nftContractAddress,
        uint256 _agreementId,
        uint256 _nftTokenId
    ) public payable CanClaim(_agreementId) {
        Agreements storage agreement = agreements[_agreementId];
        uint bal = totalPayForSeller[_agreementId][msg.sender];
        uint sellersCompensation  = ((bal * 5 )/100);
        //Smart contract sends compensation ether to the seller
         payable(msg.sender).transfer(sellersCompensation);
        
        //Smart contract sends token to the seller
        IERC721(_nftContractAddress).safeTransferFrom(
            address(this),
            msg.sender,
            _nftTokenId
        );
        agreements[_agreementId].saleEnded = true;
        
        emit SellerClaim(_nftTokenId, msg.sender);
        emit AgreementEnded(_nftTokenId, msg.sender, agreement.saleEnded);
    }

    //BuyerClaimFund function is used by the buyer to claim his nft when he fails to pay all installment before the end of the agreement period
    function buyerClaimFund(
        uint256 _agreementId,
        uint256 _nftTokenId)
        external
        CanClaim(_agreementId)
        returns (bool success)
    {
        Agreements storage agreement = agreements[_agreementId];
        //calculate buyer's due
        uint256 bal = agreement.bit[msg.sender];
        uint256 buyersDue = (bal * 90) / 100;
        uint256 contractFee =(bal *5) / 100;
        //Smart contract sends ether to the buyer
         payable(msg.sender).transfer(buyersDue);
            
        //Smart contract sends ether to the owner
         payable(msg.sender).transfer(contractFee);
        
        agreements[_agreementId].saleEnded = true;
        emit BuyerClaim(_nftTokenId, msg.sender);
        emit AgreementEnded(
            _nftTokenId,
            msg.sender,
            agreements[_agreementId].saleEnded
        );
        return (success);
    }
  
    //A view function that returns  Bit-NFT-MarketPlace Commission
    function getBitMktCommision(uint256 _agreementId)
        public
        view
        returns (uint256)
    {
        return (agreements[_agreementId].price * 5) / 100;
    }

    //A view function that returns the fund receivable by an NFT seller
    function getSellersFundReceivable(uint256 _agreementId)
        public
        view
        returns (uint256)
    {
        return (agreements[_agreementId].price * 95) / 100;
    }

    //receive function helps the smart contract to receive ether
    receive() external payable {
        emit Received(msg.sender, msg.value, "Fallback was called");
    }

    // onERC721Received function helps the smart contract to receive NFT
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

