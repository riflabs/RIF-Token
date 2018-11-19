#!/bin/bash

release="v1.12.0"
repopath="https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-solidity/$release/contracts/"

echo "Checking against release $release..."

files=`find ./ -type f -name "*.sol"`

while read -r file
do
    output=`curl -s $repopath$file | diff $file -`
    if [[ $? != 0 ]]
    then 
        echo $file
        echo "$output"
    else
        echo "$file - OK"
    fi
done <<< $files

