#!/bin/bash

# run consumer
./consumer &

# run producer
./producer

wait