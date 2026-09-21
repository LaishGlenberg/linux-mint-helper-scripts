#!/bin/bash
state=$(gsettings get org.cinnamon panels-autohide)
if [[ $state = "['1:true', '2:false']" ]]; then
    gsettings set org.cinnamon panels-autohide "['1:false', '2:true']"
else
    gsettings set org.cinnamon panels-autohide "['1:true', '2:false']"
fi
